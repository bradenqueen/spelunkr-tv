import Foundation
import Observation

/// Loads spelunkr's public schedule data, feeds it to the engine, and keeps the guide fresh.
@MainActor
@Observable
final class BroadcastStore {
    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// The schedule format this build of the engine was extracted for.
    static let supportedEngine = 5

    /// Live data first, then the copy the website ships with itself.
    nonisolated static let sources = [
        URL(string: "https://data.spelunkr.tv/")!,
        URL(string: "https://spelunkr.tv/broadcast/")!,
    ]

    private(set) var status: Status = .loading
    private(set) var channels: [ChannelInfo] = []
    private(set) var guide: [String: [GuideEntry]] = [:]
    private(set) var audioBase = URL(string: "https://audio.spelunkr.tv/bumps/")!
    private(set) var engineWarning: String?
    private(set) var detailsRevision: Int = 0
    private(set) var scheduleRevision: Int = 0

    let engine: ScheduleEngine?
    let tv: TVPlayer
    let presence = PresenceClient()
    /// Per-tape picture corrections (stretch / zoom) from spelunkr.tv.
    let aspectFixes = AspectFixes()

    @ObservationIgnored private var dataBase: URL = sources[0]
    @ObservationIgnored private var platformCache: [String: String] = [:]
    @ObservationIgnored private var detailsCache: [String: [ShowDetail?]] = [:]
    @ObservationIgnored private var detailsInFlight: Set<String> = []
    @ObservationIgnored private var blocksCache: [String: [GuideBlock]] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshInProgress = false
    @ObservationIgnored private var guideRequest = 0

    var canRetryStartup: Bool { engine != nil }

    init() {
        engine = try? ScheduleEngine()
        tv = TVPlayer()
        tv.store = self
    }

    var watchableChannels: [ChannelInfo] { channels.filter(\.isWatchable) }

    func start() {
        guard !started else { return }
        started = true
        Task {
            if let cfg = await engine?.presenceConfig() {
                presence.configure(urlString: cfg.url, key: cfg.key)
            }
            presence.connect()
        }
        Task { await aspectFixes.load() }
        Task { await refreshLoop() }
        Task { await guideLoop() }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            // New schedule versions are published ahead of time; every few minutes is plenty.
            try? await Task.sleep(for: .seconds(status == .ready ? 300 : 15))
        }
    }

    private func guideLoop() async {
        while !Task.isCancelled {
            await refreshGuide()
            try? await Task.sleep(for: .seconds(20))
        }
    }

    func refresh(userInitiated: Bool = false) async {
        guard let engine else {
            status = .failed("The schedule engine is missing from the app bundle.")
            return
        }
        if userInitiated && channels.isEmpty { status = .loading }
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        do {
            let (lineup, base) = try await Self.fetchLineup()
            dataBase = base
            if let a = lineup.audioBase, let u = URL(string: a) { audioBase = ArchiveMedia.secure(u) }
            if let e = lineup.engine, e > Self.supportedEngine {
                engineWarning = "Spelunkr changed its schedule format (engine \(e)). Run tools/update-engine.mjs and rebuild, or some channels may drift."
            } else {
                engineWarning = nil
            }

            let visible = lineup.channels
                .filter { $0.debugOnly != true && !$0.versions.isEmpty }
                .sorted { ($0.dial ?? .max) < ($1.dial ?? .max) }

            // Which schedule versions does the engine not have yet?
            var needed: [(channel: String, pointer: VersionPointer)] = []
            for ch in visible {
                for v in ch.versions {
                    let known = await engine.hasVersion(channel: ch.id, v: v.v)
                    if !known { needed.append((ch.id, v)) }
                }
            }

            // Download their manifests in parallel.
            let manifests: [(String, VersionPointer, String)] = await withTaskGroup(of: (String, VersionPointer, String)?.self) { group in
                for (channel, pointer) in needed {
                    group.addTask {
                        guard let text = await Self.fetchResource(pointer.manifest, base: base, validating: {
                            guard let manifest = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any],
                                  manifest["items"] is [Any] else { return false }
                            let platform = manifest["platform"]
                            return platform == nil || platform is NSNull || platform is String
                        }) else { return nil }
                        return (channel, pointer, text)
                    }
                }
                var out: [(String, VersionPointer, String)] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }

            // Each manifest points at a shared "platform" file of spelunkr-wide bumpers.
            var attemptedPlatforms = Set<String>()
            for (_, _, text) in manifests {
                guard let path = (try? JSONDecoder().decode(ManifestHead.self, from: Data(text.utf8)))?.platform,
                      platformCache[path] == nil,
                      attemptedPlatforms.insert(path).inserted,
                      let platform = await Self.fetchResource(path, base: base, validating: {
                          (try? JSONSerialization.jsonObject(with: Data($0.utf8))) is [String: Any]
                      }) else { continue }
                platformCache[path] = platform
            }

            var addedVersion = false
            for (channel, pointer, text) in manifests.sorted(by: { $0.1.v < $1.1.v }) {
                let path = (try? JSONDecoder().decode(ManifestHead.self, from: Data(text.utf8)))?.platform
                if let path, platformCache[path] == nil { continue }
                do {
                    try await engine.addVersion(channel: channel, manifest: text,
                                                platform: path.flatMap { platformCache[$0] },
                                                pointer: pointer)
                    addedVersion = true
                } catch {
                    print("[store] \(channel) v\(pointer.v): \(error.localizedDescription)")
                }
            }

            var ready: [ChannelInfo] = []
            for ch in visible {
                let onAir = await engine.onAir(channel: ch.id, atMs: Date.nowMs)
                if onAir != nil { ready.append(ch) }
            }
            let previousIDs = channels.map(\.id)
            if !ready.isEmpty || channels.isEmpty { channels = ready }
            if addedVersion || previousIDs != channels.map(\.id) {
                blocksCache.removeAll()
                scheduleRevision += 1
            }
            status = channels.isEmpty ? .failed("No channels could be loaded.") : .ready
            await refreshGuide()
        } catch {
            if channels.isEmpty {
                status = .failed("Couldn't reach spelunkr.tv. Check the Apple TV's internet connection.")
            }
            print("[store] refresh failed: \(error)")
        }
    }

    func refreshGuide() async {
        guard let engine, status == .ready else { return }
        let now = Date.nowMs
        guideRequest += 1
        let request = guideRequest
        let revision = scheduleRevision
        var g: [String: [GuideEntry]] = [:]
        for ch in channels {
            g[ch.id] = await engine.upcoming(channel: ch.id, atMs: now, count: 4)
        }
        guard revision == scheduleRevision, request == guideRequest else { return }
        guide = g
        await prefetchServers(engine: engine, at: now)
    }

    /// Warms the storage-server cache for what is on now across every channel (skips ids already known),
    /// so the guide preview and channel changes find a direct URL. Runs in the background; never awaited by tuning.
    private func prefetchServers(engine: ScheduleEngine, at now: Double) async {
        var ids: [String] = []
        for ch in watchableChannels {
            if let onNow = await engine.onAir(channel: ch.id, atMs: now), onNow.isTape, onNow.file != nil, let id = onNow.id {
                ids.append(id)
            }
        }
        tv.prefetchServers(forIDs: ids)
    }

    // MARK: - Grid windows & channel schedules (cached per window)

    func blocks(for channelID: String, fromMs: Double, toMs: Double) async -> [GuideBlock] {
        let key = "\(channelID)|\(Int64(fromMs))|\(Int64(toMs))"
        if let cached = blocksCache[key] { return cached }
        guard let engine else { return [] }
        let revision = scheduleRevision
        let computed = await engine.blocks(channel: channelID, fromMs: fromMs, toMs: toMs)
        guard revision == scheduleRevision else { return [] }
        if blocksCache.count > 240 { blocksCache.removeAll() }
        blocksCache[key] = computed
        return computed
    }

    func programs(for channelID: String, fromMs: Double, toMs: Double) async -> [GuideProgram] {
        guard let engine else { return [] }
        let revision = scheduleRevision
        let programs = await engine.range(channel: channelID, fromMs: fromMs, toMs: toMs)
        return revision == scheduleRevision ? programs : []
    }

    // MARK: - Show details (blurbs)

    func detail(channelID: String, version: Int?, videoIndex: Int?) -> ShowDetail? {
        guard let version, let videoIndex, videoIndex >= 0 else { return nil }
        let key = "\(channelID)-v\(version)"
        guard let items = detailsCache[key], videoIndex < items.count else { return nil }
        return items[videoIndex]
    }

    func ensureDetails(for channel: ChannelInfo) async {
        let base = dataBase
        for ptr in channel.versions {
            guard let path = ptr.details, !path.isEmpty else { continue }
            let key = "\(channel.id)-v\(ptr.v)"
            guard detailsCache[key] == nil, !detailsInFlight.contains(key) else { continue }
            detailsInFlight.insert(key)
            defer { detailsInFlight.remove(key) }
            guard let url = URL(string: path, relativeTo: base),
                  let decoded = try? await Self.fetchDetails(url.absoluteURL) else {
                continue
            }
            detailsCache[key] = decoded.items
            detailsRevision += 1
        }
    }

    // MARK: - Networking

    private nonisolated static func fetchDetails(_ url: URL) async throws -> DetailsFile {
        let text = try await fetchText(url)
        return try JSONDecoder().decode(DetailsFile.self, from: Data(text.utf8))
    }

    private nonisolated static func fetchResource(_ path: String, base: URL,
                                                  validating: @Sendable (String) -> Bool) async -> String? {
        var attempted = Set<URL>()
        for source in [base] + sources {
            guard let url = URL(string: path, relativeTo: source)?.absoluteURL,
                  attempted.insert(url).inserted else { continue }
            if let text = try? await fetchText(url), validating(text) { return text }
        }
        return nil
    }

    nonisolated static func fetchLineup() async throws -> (Lineup, URL) {
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for base in sources {
            do {
                let text = try await fetchText(base.appendingPathComponent("lineup.json"))
                let lineup = try JSONDecoder().decode(Lineup.self, from: Data(text.utf8))
                return (lineup, base)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    nonisolated static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: ArchiveMedia.secure(url), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("SpelunkrTV/0.1 (tvOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
