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

    let engine: ScheduleEngine?
    let tv: TVPlayer
    /// Per-tape picture corrections (stretch / zoom) from spelunkr.tv.
    let aspectFixes = AspectFixes()
    @ObservationIgnored private var platformCache: [String: String] = [:]
    @ObservationIgnored private var started = false

    init() {
        engine = try? ScheduleEngine()
        tv = TVPlayer()
        tv.store = self
    }

    var watchableChannels: [ChannelInfo] { channels.filter(\.isWatchable) }

    func start() {
        guard !started else { return }
        started = true
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

    func refresh() async {
        guard let engine else {
            status = .failed("The schedule engine is missing from the app bundle.")
            return
        }
        do {
            let (lineup, base) = try await Self.fetchLineup()
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
                        guard let url = URL(string: pointer.manifest, relativeTo: base),
                              let text = try? await Self.fetchText(url.absoluteURL) else { return nil }
                        return (channel, pointer, text)
                    }
                }
                var out: [(String, VersionPointer, String)] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }

            // Each manifest points at a shared "platform" file of spelunkr-wide bumpers.
            for (_, _, text) in manifests {
                guard let path = (try? JSONDecoder().decode(ManifestHead.self, from: Data(text.utf8)))?.platform,
                      platformCache[path] == nil,
                      let url = URL(string: path, relativeTo: base) else { continue }
                platformCache[path] = try? await Self.fetchText(url.absoluteURL)
            }

            for (channel, pointer, text) in manifests.sorted(by: { $0.1.v < $1.1.v }) {
                let path = (try? JSONDecoder().decode(ManifestHead.self, from: Data(text.utf8)))?.platform
                do {
                    try await engine.addVersion(channel: channel, manifest: text,
                                                platform: path.flatMap { platformCache[$0] },
                                                pointer: pointer)
                } catch {
                    print("[store] \(channel) v\(pointer.v): \(error.localizedDescription)")
                }
            }

            var ready: [ChannelInfo] = []
            for ch in visible {
                let onAir = await engine.onAir(channel: ch.id, atMs: Date.nowMs)
                if onAir != nil { ready.append(ch) }
            }
            channels = ready
            status = ready.isEmpty ? .failed("No channels could be loaded.") : .ready
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
        var g: [String: [GuideEntry]] = [:]
        for ch in channels {
            g[ch.id] = await engine.upcoming(channel: ch.id, atMs: now, count: 3)
        }
        guide = g
    }

    // MARK: - Networking

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
