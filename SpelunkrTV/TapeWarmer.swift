import AVFoundation
import Foundation

/// Keeps a few tapes "warm" so tuning to them is fast: their AVURLAsset has already followed the
/// archive.org redirect and downloaded and parsed the MP4 header (moov atom). Also remembers each
/// item's direct storage server (from archive.org/metadata) so later loads skip the 302 hop.
///
/// Everything is keyed by the canonical address (https://archive.org/download/<id>/<file>), which is
/// also what AspectFixes needs; the direct address is only ever used to load media.
@MainActor
final class TapeWarmer {
    static let capacity = 3
    static let warmTimeout: Double = 60
    /// Tapes whose moov atom is larger than this are not warmed speculatively (with a direct address a
    /// 20 to 30 MB header parses in a few seconds; beyond this it competes with the tape being watched).
    static let maxWarmMoov = 40_000_000
    /// How many storage-server lookups the background pre-resolve runs at once (each is two small requests).
    private static let prefetchConcurrency = 3
    private static let staleAfter: TimeInterval = 600
    private static let serverTTL: TimeInterval = 1800
    private static let serverFailureTTL: TimeInterval = 120

    struct Server: Sendable {
        let d1: String
        let dir: String
    }

    struct Target {
        let canonical: URL
        let moov: Int?
    }

    /// A warmed asset handed to the player. `ready` is true once its header has been parsed.
    struct Taken {
        let tape: TapeLoader.Tape
        let ready: Bool
    }

    private final class Entry {
        let key: String
        let canonical: URL
        let created = Date()
        var startedMs: Double = Date.nowMs
        var tape: TapeLoader.Tape?
        var loaded = false
        var lastUsed = 0
        var task: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        init(key: String, canonical: URL) { self.key = key; self.canonical = canonical }
    }

    private var entries: [String: Entry] = [:]
    private var wanted: Set<String> = []
    private var tick = 0
    private var servers: [String: (server: Server?, at: Date)] = [:]
    private var lookups: [String: Task<Server?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?

    // MARK: - Using the cache

    /// Hands over the warmed asset for `canonical` (removing it from the cache; the player owns it now),
    /// or nil if there isn't one. An asset whose header is still loading is returned too: the player
    /// item joins that load instead of starting a second one.
    func take(_ canonical: URL) -> Taken? {
        let key = canonical.absoluteString
        guard let entry = entries.removeValue(forKey: key) else {
            TuneLog.info("[warmer] take miss (not in cache): \(TuneLog.short(canonical)); cached: \(entries.values.map { TuneLog.short($0.canonical) }.joined(separator: ", "))")
            return nil
        }
        entry.watchdog?.cancel()
        guard let tape = entry.tape, Date().timeIntervalSince(entry.created) < Self.staleAfter else {
            TuneLog.info("[warmer] take dropped (no asset yet or stale): \(TuneLog.short(canonical))")
            // Still looking up the server (nothing to join) or too old: drop it.
            entry.task?.cancel()
            entry.tape?.asset.cancelLoading()
            return nil
        }
        // The warm task is left to finish by itself: it finds the entry gone and does nothing.
        TuneLog.info("[warmer] take hit: \(TuneLog.short(canonical)) loaded=\(entry.loaded) age=\(Int(Date().timeIntervalSince(entry.created)))s")
        return Taken(tape: tape, ready: entry.loaded)
    }

    /// Takes back the parsed asset of a tape the player is leaving, so tuning straight back is a warm tune.
    func keep(_ tape: TapeLoader.Tape, canonical: URL) {
        let key = canonical.absoluteString
        guard entries[key] == nil else { return }
        makeRoom()
        let entry = Entry(key: key, canonical: canonical)
        entry.tape = tape
        entry.loaded = true
        tick += 1
        entry.lastUsed = tick
        entries[key] = entry
        TuneLog.info("[warmer] kept departing asset: \(TuneLog.short(canonical))")
    }

    /// The direct storage address for a tape, if a warm already found its server. Never does any I/O.
    func directURL(for canonical: URL) -> URL? {
        guard let (id, file) = Self.parts(of: canonical),
              let cached = servers[id], let server = cached.server,
              Date().timeIntervalSince(cached.at) < Self.serverTTL else { return nil }
        return Self.directURL(server: server, file: file)
    }

    /// Where a tune's direct address came from, for the tune log.
    enum DirectSource: Sendable {
        case cached
        case resolved(ms: Int)
        case fallback(String)

        var description: String {
            switch self {
            case .cached: return "cached"
            case .resolved(let ms): return "resolved now in \(ms)ms"
            case .fallback(let why): return "fallback to redirect (\(why))"
            }
        }
        var isDirect: Bool {
            if case .fallback = self { return false }
            return true
        }
    }

    /// The direct storage address for a tape: from the cache if known, otherwise looked up now,
    /// waiting at most `timeout` seconds. nil (with the reason) means: load archive.org/download.
    /// A lookup that outlives the timeout carries on in the background and fills the cache.
    func resolveDirectURL(for canonical: URL, timeout: Double) async -> (url: URL?, source: DirectSource) {
        guard let (id, file) = Self.parts(of: canonical) else { return (nil, .fallback("unparsable address")) }
        let began = Date.nowMs
        if let cached = servers[id], Date().timeIntervalSince(cached.at) < (cached.server == nil ? Self.serverFailureTTL : Self.serverTTL) {
            guard let server = cached.server, let url = Self.directURL(server: server, file: file) else {
                return (nil, .fallback("lookup failed recently"))
            }
            return (url, .cached)
        }
        let lookup = lookupTask(for: id)
        // Not a task group: awaiting a Task's value ignores cancellation, so a group would wait for the whole lookup.
        let server: Server? = await withCheckedContinuation { (continuation: CheckedContinuation<Server?, Never>) in
            let once = Once()
            Task { @MainActor in
                let result = await lookup.value
                if once.finish() { continuation.resume(returning: result) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if once.finish() { continuation.resume(returning: nil) }
            }
        }
        guard !Task.isCancelled else { return (nil, .fallback("cancelled")) }
        guard let server, let url = Self.directURL(server: server, file: file) else {
            let waited = Int(Date.nowMs - began)
            return (nil, .fallback(waited >= Int(timeout * 1000) - 50 ? "lookup timed out after \(waited)ms" : "lookup failed after \(waited)ms"))
        }
        return (url, .resolved(ms: Int(Date.nowMs - began)))
    }

    /// Lets exactly one of two racing tasks resume a continuation.
    @MainActor private final class Once {
        private var done = false
        func finish() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }

    /// Looks up the storage servers of these items in the background (a few at a time), skipping ids that
    /// are already known or already being looked up. Never blocks anything; a newer call replaces the
    /// queue of an older one, but lookups already under way finish and are cached either way.
    func prefetchServers(forIDs ids: [String]) {
        var seen = Set<String>()
        let todo = ids.filter { id in
            guard seen.insert(id).inserted else { return false }
            if let cached = servers[id], Date().timeIntervalSince(cached.at) < (cached.server == nil ? Self.serverFailureTTL : Self.serverTTL) { return false }
            return true
        }
        guard !todo.isEmpty else { return }
        TuneLog.info("[warmer] pre-resolving \(todo.count) storage servers")
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let warmer = self else { return }
            let began = Date.nowMs
            var found = 0
            await withTaskGroup(of: Bool.self) { group in
                var iterator = todo.makeIterator()
                var running = 0
                while running < Self.prefetchConcurrency, let id = iterator.next() {
                    group.addTask { await warmer.server(for: id) != nil }
                    running += 1
                }
                while let ok = await group.next() {
                    if ok { found += 1 }
                    if !Task.isCancelled, let id = iterator.next() {
                        group.addTask { await warmer.server(for: id) != nil }
                    }
                }
            }
            if !Task.isCancelled {
                TuneLog.info("[warmer] pre-resolved \(found)/\(todo.count) storage servers in \(Int(Date.nowMs - began))ms")
            }
        }
    }

    /// Called when a direct address didn't work: use archive.org/download for this item for a while.
    func forgetServer(for canonical: URL) {
        guard let (id, _) = Self.parts(of: canonical) else { return }
        servers[id] = (nil, Date())
    }

    // MARK: - Choosing what to warm

    /// Warms these addresses (most important first; at most `capacity`), and stops warming
    /// anything that is still loading and no longer wanted. Finished warms that are no longer
    /// wanted stay until the LRU needs the room.
    func setWanted(_ targets: [Target]) {
        let list = Array(targets.prefix(Self.capacity))
        wanted = Set(list.map { $0.canonical.absoluteString })
        TuneLog.info("[warmer] wanted: \(list.map { TuneLog.short($0.canonical) }.joined(separator: ", "))")
        for entry in Array(entries.values) where !wanted.contains(entry.key) && !entry.loaded {
            evict(entry)
        }
        for target in list {
            let key = target.canonical.absoluteString
            if let existing = entries[key] {
                tick += 1
                existing.lastUsed = tick
                continue
            }
            start(target, key: key)
        }
    }

    /// Stops every warm that has not finished, so nothing competes with a tape being tuned.
    func cancelPending() {
        let pending = entries.values.filter { !$0.loaded }
        if !pending.isEmpty { TuneLog.info("[warmer] cancelPending: \(pending.count) in flight") }
        for entry in Array(entries.values) where !entry.loaded { evict(entry) }
    }

    /// Cancels everything and empties the cache (leaving the player).
    func cancelAll() {
        for entry in Array(entries.values) { evict(entry) }
        wanted = []
        // Server lookups in flight are left to finish (they are tiny and fill the cache); only the queue stops.
        prefetchTask?.cancel(); prefetchTask = nil
    }

    // MARK: - Warming one tape

    private func start(_ target: Target, key: String) {
        makeRoom()
        let url = target.canonical
        let entry = Entry(key: key, canonical: url)
        TuneLog.info("[warmer] start: \(TuneLog.short(url))")
        tick += 1
        entry.lastUsed = tick
        entries[key] = entry
        entry.task = Task { [weak self] in await self?.warm(entry, moov: target.moov) }
        entry.watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.warmTimeout))
            guard !Task.isCancelled, let self else { return }
            if !entry.loaded, self.entries[entry.key] === entry { self.evict(entry) }
        }
    }

    private func warm(_ entry: Entry, moov: Int?) async {
        guard let (id, file) = Self.parts(of: entry.canonical) else { evict(entry); return }
        var loadURL = entry.canonical
        let serverFound = await server(for: id)
        if let server = serverFound, let direct = Self.directURL(server: server, file: file) {
            loadURL = direct
        }
        TuneLog.info("[warmer] metadata lookup \(serverFound == nil ? "failed/none" : "ok") after \(Int(Date.nowMs - entry.startedMs))ms: \(TuneLog.short(entry.canonical))")
        guard !Task.isCancelled, entries[entry.key] === entry else { return }

        let playable: Bool
        do {
            let tape = try await TapeLoader.prepare(canonical: entry.canonical, url: loadURL, moov: moov)
            guard !Task.isCancelled, entries[entry.key] === entry else { return }
            entry.tape = tape
            // Parses the moov atom now, so a player item made from this asset is ready almost at once.
            let loaded = try await tape.asset.load(.isPlayable, .duration, .tracks)
            playable = loaded.0
        } catch {
            TuneLog.info("[warmer] header load failed after \(Int(Date.nowMs - entry.startedMs))ms: \(TuneLog.short(entry.canonical)) \(error.localizedDescription)")
            if entries[entry.key] === entry { evict(entry) }
            return
        }
        guard !Task.isCancelled, entries[entry.key] === entry else { return }
        guard playable else { evict(entry); return }
        entry.loaded = true
        entry.watchdog?.cancel()
        TuneLog.info("[warmer] finished (header parsed) in \(Int(Date.nowMs - entry.startedMs))ms: \(TuneLog.short(entry.canonical))")
    }

    private func evict(_ entry: Entry) {
        if entries[entry.key] === entry {
            entries[entry.key] = nil
            TuneLog.info("[warmer] evict (loaded=\(entry.loaded)): \(TuneLog.short(entry.canonical))")
        }
        entry.task?.cancel()
        entry.watchdog?.cancel()
        entry.tape?.asset.cancelLoading()
    }

    /// Least recently used first, but anything no longer wanted goes before anything still wanted.
    private func makeRoom() {
        while entries.count >= Self.capacity {
            let all = Array(entries.values)
            let pool = all.filter { !wanted.contains($0.key) }
            guard let victim = (pool.isEmpty ? all : pool).min(by: { $0.lastUsed < $1.lastUsed }) else { return }
            evict(victim)
        }
    }

    // MARK: - Direct storage addresses

    private func server(for id: String) async -> Server? {
        if let cached = servers[id] {
            let ttl = cached.server == nil ? Self.serverFailureTTL : Self.serverTTL
            if Date().timeIntervalSince(cached.at) < ttl { return cached.server }
        }
        return await lookupTask(for: id).value
    }

    /// The (shared) lookup for one item. It records its own result, so a caller that stops waiting
    /// early (a tune's short timeout) does not lose it.
    private func lookupTask(for id: String) -> Task<Server?, Never> {
        if let running = lookups[id] { return running }
        let task = Task { [weak self] () -> Server? in
            let result = await Self.fetchServer(id: id)
            if let self, !Task.isCancelled {
                self.servers[id] = (result, Date())
                self.lookups[id] = nil
            }
            return result
        }
        lookups[id] = task
        return task
    }

    /// archive.org/metadata/<id>/d1 and /dir (a few dozen bytes each, unlike the full metadata, which can
    /// be hundreds of KB), fetched in parallel. Gives up after 6 s.
    nonisolated private static func fetchServer(id: String) async -> Server? {
        async let d1 = fetchResult(id: id, field: "d1")
        async let dir = fetchResult(id: id, field: "dir")
        return validate(d1: await d1, dir: await dir)
    }

    nonisolated private static func fetchResult(id: String, field: String) async -> String? {
        guard let url = URL(string: "https://archive.org/metadata/\(ArchiveMedia.encodeComponent(id))/\(field)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 6)
        request.setValue("SpelunkrTV/0.1 (tvOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return reply.result
    }

    /// {"result": "..."}, or {"error": "..."} for an item without that field.
    private struct Reply: Decodable {
        let result: String?
    }

    /// The host must look like a name under archive.org and the directory must be an absolute path.
    nonisolated static func validate(d1: String?, dir: String?) -> Server? {
        guard let d1, let dir,
              d1.range(of: #"^([A-Za-z0-9-]+\.)+archive\.org$"#, options: .regularExpression) != nil,
              dir.hasPrefix("/"), !dir.contains(".."), !dir.contains("?"), !dir.contains("#"),
              !dir.contains(" ") else { return nil }
        return Server(d1: d1, dir: dir)
    }

    /// https://<d1><dir>/<file>, each path segment of the file name percent-encoded (as the site does).
    nonisolated static func directURL(server: Server, file: String) -> URL? {
        let path = file.split(separator: "/", omittingEmptySubsequences: false)
            .map { ArchiveMedia.encodeComponent(String($0)) }
            .joined(separator: "/")
        return URL(string: "https://\(server.d1)\(server.dir)/\(path)")
    }

    /// Item id and file name of a canonical download address.
    nonisolated static func parts(of canonical: URL) -> (id: String, file: String)? {
        guard let key = AspectFixes.key(for: canonical), let slash = key.firstIndex(of: "/") else { return nil }
        let id = String(key[..<slash]), file = String(key[key.index(after: slash)...])
        return id.isEmpty || file.isEmpty ? nil : (id, file)
    }
}
