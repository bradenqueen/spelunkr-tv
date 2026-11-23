import Foundation
import Observation

/// Tracks live viewer counts and reports this Apple TV as an active viewer using the same
/// protocol as spelunkr.tv:
/// - Reads counts from `https://data.spelunkr.tv/live.json` (falling back to the site's
///   `rpc/viewer_counts` endpoint) roughly every 2 minutes.
/// - Reports watching state via `rpc/heartbeat`, `rpc/heartbeat_move`, and `rpc/heartbeat_end`
///   with a 3-second channel-settle delay and a 4-minute heartbeat interval.
@MainActor
@Observable
final class PresenceClient {
    nonisolated private static let liveJSONURL = URL(string: "https://data.spelunkr.tv/live.json")!

    private static let pollIntervalSeconds: Double = 120
    private static let pollJitterSeconds: Double = 20
    private static let heartbeatIntervalSeconds: Double = 240
    private static let settleDelaySeconds: Double = 3
    private static let heartbeatWindowMs: Double = 510_000
    private static let clockSlopMs: Double = 5_000
    private static let historyRetentionMs: Double = 720_000

    private(set) var channelCounts: [String: Int] = [:]
    private(set) var totalViewers: Int = 0
    private(set) var isConnected: Bool = false

    @ObservationIgnored private let sessionID = UUID().uuidString.lowercased()
    @ObservationIgnored private var endpointURL: URL?
    @ObservationIgnored private var publicKey: String?
    @ObservationIgnored private var rawOthers: [String: Int] = [:]
    @ObservationIgnored private var activeChannel: String?
    @ObservationIgnored private var reportedChannel: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var beatHistory: [String: [BeatEvent]] = [:]

    private struct BeatEvent {
        let sentMs: Double?
        let ackedMs: Double?
        let leftMs: Double?
    }

    func configure(urlString: String?, key: String?) {
        if let urlString, let u = URL(string: urlString) {
            self.endpointURL = u
        }
        if let key, !key.isEmpty {
            self.publicKey = key
        }
    }

    func connect() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func disconnect() {
        pollTask?.cancel(); pollTask = nil
        settleTask?.cancel(); settleTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        let leaving = reportedChannel
        let url = endpointURL
        let key = publicKey
        activeChannel = nil
        reportedChannel = nil
        isConnected = false
        recomputeCounts()
        if let leaving, let url, let key {
            recordLeave(channel: leaving, atMs: Date.nowMs)
            Task { await Self.sendHeartbeatEnd(baseURL: url, key: key, session: sessionID, channel: leaving) }
        }
    }

    /// Call whenever the user tunes to a channel (preview or full screen), or `nil` when idle.
    func track(channelID: String?) {
        guard channelID != activeChannel else { return }
        settleTask?.cancel(); settleTask = nil
        activeChannel = channelID
        recomputeCounts()

        guard let target = channelID else {
            heartbeatTask?.cancel(); heartbeatTask = nil
            if let prev = reportedChannel {
                reportedChannel = nil
                recordLeave(channel: prev, atMs: Date.nowMs)
                if let url = endpointURL, let key = publicKey {
                    Task { await Self.sendHeartbeatEnd(baseURL: url, key: key, session: sessionID, channel: prev) }
                }
            }
            return
        }

        let delay: Double = reportedChannel == nil ? 0 : Self.settleDelaySeconds
        settleTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self, self.activeChannel == target else { return }
            self.startHeartbeatLoop(for: target)
        }
    }

    func count(for channelID: String) -> Int {
        channelCounts[channelID] ?? 0
    }

    /// Formats viewer counts matching spelunkr.tv's `Sa()` (e.g. 1600 -> "1.6K", 12000 -> "12K").
    static func formatCount(_ count: Int) -> String {
        let n = max(0, count)
        if n >= 10_000 {
            return "\(n / 1_000)K"
        }
        if n >= 1_000 {
            let tenths = Double(n / 100) / 10.0
            let formatted = String(format: "%.1f", tenths)
            return (formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted) + "K"
        }
        return "\(n)"
    }

    // MARK: - Polling viewer counts

    private func pollLoop() async {
        try? await Task.sleep(for: .milliseconds(Int.random(in: 500...1500)))
        var failures = 0
        while !Task.isCancelled {
            if let counts = await fetchViewerCounts() {
                rawOthers = counts
                isConnected = true
                failures = 0
                recomputeCounts()
            } else {
                failures = min(failures + 1, 4)
            }
            let backoffMul = failures == 0 ? 1.0 : pow(2.0, Double(failures))
            let jitter = Double.random(in: -Self.pollJitterSeconds...Self.pollJitterSeconds)
            let wait = max(15, min(960, Self.pollIntervalSeconds * backoffMul + jitter))
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func fetchViewerCounts() async -> [String: Int]? {
        if let live = await Self.fetchLiveJSON() {
            let atMs = live.atMs
            var others: [String: Int] = [:]
            for (ch, count) in live.byChannel {
                let adjusted = count - (wasCountedInSnapshot(channel: ch, atMs: atMs) ? 1 : 0)
                if adjusted > 0 { others[ch] = adjusted }
            }
            return others
        }
        if let url = endpointURL, let key = publicKey,
           let rows = await Self.fetchViewerCountsRPC(baseURL: url, key: key, session: sessionID) {
            var others: [String: Int] = [:]
            for row in rows where row.viewers > 0 {
                others[row.channelId, default: 0] += row.viewers
            }
            return others
        }
        return nil
    }

    private func recomputeCounts() {
        var combined = rawOthers
        if let active = activeChannel {
            combined[active, default: 0] += 1
        }
        channelCounts = combined
        totalViewers = combined.values.reduce(0, +)
    }

    // MARK: - Heartbeats

    private func startHeartbeatLoop(for channel: String) {
        heartbeatTask?.cancel()
        guard let url = endpointURL, let key = publicKey else { return }
        let previous = reportedChannel
        reportedChannel = channel

        heartbeatTask = Task { [weak self] in
            var leftChannel = previous != channel ? previous : nil
            while !Task.isCancelled {
                guard let self else { return }
                let sentMs = Date.nowMs
                var moved = false
                var ok = false
                if let left = leftChannel {
                    let result = await Self.sendHeartbeatMove(baseURL: url, key: key, session: self.sessionID, channel: channel, left: left)
                    if result {
                        moved = true
                        ok = true
                    }
                    leftChannel = nil
                }
                if !ok {
                    ok = await Self.sendHeartbeat(baseURL: url, key: key, session: self.sessionID, channel: channel)
                }
                if Task.isCancelled || self.activeChannel != channel {
                    if !moved, let prev = previous, prev != channel {
                        self.recordLeave(channel: prev, atMs: Date.nowMs)
                        await Self.sendHeartbeatEnd(baseURL: url, key: key, session: self.sessionID, channel: prev)
                    }
                    await Self.sendHeartbeatEnd(baseURL: url, key: key, session: self.sessionID, channel: channel)
                    return
                }
                if ok {
                    self.recordBeat(channel: channel, sentMs: sentMs, ackedMs: Date.nowMs)
                }
                if !moved, let prev = previous, prev != channel {
                    self.recordLeave(channel: prev, atMs: Date.nowMs)
                    await Self.sendHeartbeatEnd(baseURL: url, key: key, session: self.sessionID, channel: prev)
                }
                try? await Task.sleep(for: .seconds(Self.heartbeatIntervalSeconds))
            }
        }
    }

    private func recordBeat(channel: String, sentMs: Double, ackedMs: Double) {
        let cutoff = ackedMs - Self.historyRetentionMs
        var list = (beatHistory[channel] ?? []).filter { ($0.ackedMs ?? $0.leftMs ?? 0) > cutoff }
        list.append(BeatEvent(sentMs: sentMs, ackedMs: ackedMs, leftMs: nil))
        beatHistory[channel] = list
    }

    private func recordLeave(channel: String, atMs: Double) {
        let cutoff = atMs - Self.historyRetentionMs
        var list = (beatHistory[channel] ?? []).filter { ($0.ackedMs ?? $0.leftMs ?? 0) > cutoff }
        list.append(BeatEvent(sentMs: nil, ackedMs: nil, leftMs: atMs))
        beatHistory[channel] = list
    }

    private func wasCountedInSnapshot(channel: String, atMs: Double) -> Bool {
        let events = beatHistory[channel] ?? []
        guard let lastBeat = events.last(where: { ($0.ackedMs ?? .infinity) <= atMs - Self.clockSlopMs }),
              let sentMs = lastBeat.sentMs,
              sentMs > atMs - Self.heartbeatWindowMs + Self.clockSlopMs else {
            return false
        }
        let leftAfter = events.contains { event in
            guard let leftMs = event.leftMs else { return false }
            return leftMs >= sentMs - Self.clockSlopMs && leftMs <= atMs + Self.clockSlopMs
        }
        return !leftAfter
    }

    // MARK: - Network calls

    private struct LiveSnapshot {
        let atMs: Double
        let byChannel: [String: Int]
    }

    private struct LiveJSON: Decodable {
        let written: String?
        let at: String?
        let byChannel: [String: Int]?
    }

    private struct ViewerCountRow: Decodable {
        let channelId: String
        let viewers: Int
        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case viewers
        }
    }

    nonisolated private static func fetchLiveJSON() async -> LiveSnapshot? {
        var req = URLRequest(url: liveJSONURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.setValue("SpelunkrTV/0.1 (tvOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(LiveJSON.self, from: data),
              let byChannel = decoded.byChannel else { return nil }

        let nowMs = Date().timeIntervalSince1970 * 1000
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackISO = ISO8601DateFormatter()

        func parseMs(_ s: String?) -> Double? {
            guard let s else { return nil }
            if let d = iso.date(from: s) ?? fallbackISO.date(from: s) {
                return d.timeIntervalSince1970 * 1000
            }
            return nil
        }

        if let writtenMs = parseMs(decoded.written) {
            guard writtenMs >= nowMs - 150_000 && writtenMs <= nowMs + 60_000 else { return nil }
        }
        let atMs = parseMs(decoded.at) ?? nowMs
        return LiveSnapshot(atMs: atMs, byChannel: byChannel)
    }

    nonisolated private static func rpcRequest(baseURL: URL, key: String, path: String, body: [String: String], timeout: TimeInterval = 10) -> URLRequest {
        let url = baseURL.appendingPathComponent("rest/v1/\(path)")
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    nonisolated private static func fetchViewerCountsRPC(baseURL: URL, key: String, session: String) async -> [ViewerCountRow]? {
        let req = rpcRequest(baseURL: baseURL, key: key, path: "rpc/viewer_counts", body: ["p_session": session], timeout: 10)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode([ViewerCountRow].self, from: data)
    }

    nonisolated private static func sendHeartbeat(baseURL: URL, key: String, session: String, channel: String) async -> Bool {
        let req = rpcRequest(baseURL: baseURL, key: key, path: "rpc/heartbeat", body: ["p_session": session, "p_channel": channel], timeout: 15)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? true
    }

    nonisolated private static func sendHeartbeatMove(baseURL: URL, key: String, session: String, channel: String, left: String) async -> Bool {
        let req = rpcRequest(baseURL: baseURL, key: key, path: "rpc/heartbeat_move", body: ["p_session": session, "p_channel": channel, "p_left": left], timeout: 15)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    nonisolated private static func sendHeartbeatEnd(baseURL: URL, key: String, session: String, channel: String) async {
        let req = rpcRequest(baseURL: baseURL, key: key, path: "rpc/heartbeat_end", body: ["p_session": session, "p_channel": channel], timeout: 10)
        _ = try? await URLSession.shared.data(for: req)
    }
}