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
    private static let staleAfter: TimeInterval = 600
    private static let serverTTL: TimeInterval = 1800
    private static let serverFailureTTL: TimeInterval = 120

    struct Server: Sendable {
        let d1: String
        let dir: String
    }

    /// A warmed asset handed to the player. `ready` is true once its header has been parsed.
    struct Taken {
        let asset: AVURLAsset
        let ready: Bool
    }

    private final class Entry {
        let key: String
        let canonical: URL
        let created = Date()
        var asset: AVURLAsset?
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

    // MARK: - Using the cache

    /// Hands over the warmed asset for `canonical` (removing it from the cache; the player owns it now),
    /// or nil if there isn't one. An asset whose header is still loading is returned too: the player
    /// item joins that load instead of starting a second one.
    func take(_ canonical: URL) -> Taken? {
        let key = canonical.absoluteString
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        entry.watchdog?.cancel()
        guard let asset = entry.asset, Date().timeIntervalSince(entry.created) < Self.staleAfter else {
            // Still looking up the server (nothing to join) or too old: drop it.
            entry.task?.cancel()
            entry.asset?.cancelLoading()
            return nil
        }
        // The warm task is left to finish by itself: it finds the entry gone and does nothing.
        return Taken(asset: asset, ready: entry.loaded)
    }

    /// The direct storage address for a tape, if a warm already found its server. Never does any I/O.
    func directURL(for canonical: URL) -> URL? {
        guard let (id, file) = Self.parts(of: canonical),
              let cached = servers[id], let server = cached.server,
              Date().timeIntervalSince(cached.at) < Self.serverTTL else { return nil }
        return Self.directURL(server: server, file: file)
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
    func setWanted(_ urls: [URL]) {
        let list = Array(urls.prefix(Self.capacity))
        wanted = Set(list.map(\.absoluteString))
        for entry in Array(entries.values) where !wanted.contains(entry.key) && !entry.loaded {
            evict(entry)
        }
        for url in list {
            let key = url.absoluteString
            if let existing = entries[key] {
                tick += 1
                existing.lastUsed = tick
                continue
            }
            start(url, key: key)
        }
    }

    /// Stops every warm that has not finished, so nothing competes with a tape being tuned.
    func cancelPending() {
        for entry in Array(entries.values) where !entry.loaded { evict(entry) }
    }

    /// Cancels everything and empties the cache (leaving the player).
    func cancelAll() {
        for entry in Array(entries.values) { evict(entry) }
        wanted = []
        for task in lookups.values { task.cancel() }
        lookups = [:]
    }

    // MARK: - Warming one tape

    private func start(_ url: URL, key: String) {
        makeRoom()
        let entry = Entry(key: key, canonical: url)
        tick += 1
        entry.lastUsed = tick
        entries[key] = entry
        entry.task = Task { [weak self] in await self?.warm(entry) }
        entry.watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.warmTimeout))
            guard !Task.isCancelled, let self else { return }
            if !entry.loaded, self.entries[entry.key] === entry { self.evict(entry) }
        }
    }

    private func warm(_ entry: Entry) async {
        guard let (id, file) = Self.parts(of: entry.canonical) else { evict(entry); return }
        var loadURL = entry.canonical
        if let server = await server(for: id), let direct = Self.directURL(server: server, file: file) {
            loadURL = direct
        }
        guard !Task.isCancelled, entries[entry.key] === entry else { return }

        let asset = AVURLAsset(url: loadURL)
        entry.asset = asset
        let playable: Bool
        do {
            // Parses the moov atom now, so a player item made from this asset is ready almost at once.
            let loaded = try await asset.load(.isPlayable, .duration, .tracks)
            playable = loaded.0
        } catch {
            if entries[entry.key] === entry { evict(entry) }
            return
        }
        guard !Task.isCancelled, entries[entry.key] === entry else { return }
        guard playable else { evict(entry); return }
        entry.loaded = true
        entry.watchdog?.cancel()
    }

    private func evict(_ entry: Entry) {
        if entries[entry.key] === entry { entries[entry.key] = nil }
        entry.task?.cancel()
        entry.watchdog?.cancel()
        entry.asset?.cancelLoading()
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
        let task: Task<Server?, Never>
        if let running = lookups[id] {
            task = running
        } else {
            task = Task { await Self.fetchServer(id: id) }
            lookups[id] = task
        }
        let result = await task.value
        if !task.isCancelled {
            lookups[id] = nil
            servers[id] = (result, Date())
        }
        return result
    }

    /// archive.org/metadata/<id>: only "d1" (storage host) and "dir" are needed. Gives up after 8 s.
    nonisolated private static func fetchServer(id: String) async -> Server? {
        await withTaskGroup(of: Server?.self) { group in
            group.addTask {
                guard let url = URL(string: "https://archive.org/metadata/\(id)") else { return nil }
                var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
                request.setValue("SpelunkrTV/0.1 (tvOS)", forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let meta = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
                return validate(d1: meta.d1, dir: meta.dir)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private struct Metadata: Decodable {
        let d1: String?
        let dir: String?
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
