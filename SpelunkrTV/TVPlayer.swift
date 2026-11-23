import AVFoundation
import Combine
import CoreGraphics
import Observation

/// Plays whatever is on air on one channel, and keeps it pinned to the broadcast clock.
@MainActor
@Observable
final class TVPlayer {
    enum Phase: Equatable {
        case idle
        case tuning           // static while a tape loads
        case playing          // a tape (show or commercial) is on screen
        case card             // a station-ID / up-next card
        case problem(String)  // something couldn't play; we wait for the next item
    }

    let video = AVPlayer()
    private let music = AVPlayer()
    /// Music laid over silent tapes on "audio overlay" channels (VACATION SLIDES).
    private let overlay = AVPlayer()
    /// Faint projector hum the site plays under overlay channels.
    private let hum = AVQueuePlayer()
    @ObservationIgnored private var humLooper: AVPlayerLooper?

    private(set) var phase: Phase = .idle
    private(set) var channel: ChannelInfo?
    private(set) var onAir: OnAir?
    private(set) var isBuffering = false
    /// How to show the tape that is playing (stretch / zoom from spelunkr.tv), and the size of its picture.
    private(set) var correction = PictureCorrection.none
    private(set) var videoSize = CGSize.zero

    @ObservationIgnored weak var store: BroadcastStore?
    @ObservationIgnored private var tuneTask: Task<Void, Never>?
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var lastCorrectionMs: Double = 0
    @ObservationIgnored private var seekLag: Double = 0.5
    /// Typical seconds from starting a tune to the tape actually playing: a cold load, and one from a warmed asset.
    @ObservationIgnored private var coldStartLag: Double = 2.0
    @ObservationIgnored private var warmStartLag: Double = 0.8
    private let warmer = TapeWarmer()
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var warmLeadTask: Task<Void, Never>?
    @ObservationIgnored private var tapeURL: URL?
    @ObservationIgnored private var overlayTask: Task<Void, Never>?
    @ObservationIgnored private var overlayBoundaryTask: Task<Void, Never>?
    @ObservationIgnored private var overlayCue: OverlayCue?
    @ObservationIgnored private var overlayIsStandIn = false
    @ObservationIgnored private var overlayRecovered: OverlayCue?
    @ObservationIgnored private var overlayLag: Double = 0.4
    @ObservationIgnored private var overlayCorrectionMs: Double = 0

    @ObservationIgnored private var fullscreen = false
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var endObservers: [NSObjectProtocol] = []

    init() {
        video.automaticallyWaitsToMinimizeStalling = true
        music.volume = 0.8
        hum.volume = 0.08
    }

    // MARK: - Control

    func tune(_ ch: ChannelInfo) {
        channel = ch
        onAir = nil
        phase = .tuning
        silenceTape(resetDisplay: false)
        boundaryTask?.cancel()
        warmTask?.cancel()
        warmLeadTask?.cancel()
        tuneTask?.cancel()
        tuneTask = Task { [weak self] in await self?.playCurrent() }
        startMonitor()
    }

    func stop() {
        tuneTask?.cancel(); tuneTask = nil
        boundaryTask?.cancel(); boundaryTask = nil
        monitorTask?.cancel(); monitorTask = nil
        warmTask?.cancel(); warmTask = nil
        warmLeadTask?.cancel(); warmLeadTask = nil
        warmer.cancelAll()
        silenceTape()
        channel = nil
        onAir = nil
        phase = .idle
        isBuffering = false
    }

    // MARK: - Playback

    private func playCurrent() async {
        guard let ch = channel, let store, let engine = store.engine else { return }
        let found = await engine.onAir(channel: ch.id, atMs: Date.nowMs)
        guard !Task.isCancelled, channel?.id == ch.id else { return }
        guard let item = found else {
            silenceTape()
            warmer.cancelPending()
            phase = .problem("Nothing is scheduled on this channel right now.")
            scheduleBoundary(atMs: Date.nowMs + 30_000)
            return
        }

        onAir = item
        scheduleBoundary(atMs: item.endMs)
        if ch.audioOverlay == true { startHum() }

        guard item.isTape else {
            DisplayMatching.reset()
            video.pause()
            video.replaceCurrentItem(with: nil)
            clearPicture()
            stopOverlay()
            phase = .card
            scheduleWarms()
            await playMusic(for: item, base: store.audioBase)
            return
        }

        music.pause()
        // Music over a silent tape (overlay channels only). The tape's own sound is muted
        // (or turned down to its "ambient" level) while the music plays; commercials keep theirs.
        var tapeVolume = item.volume
        if item.type == "video" {
            let cue = await engine.overlay(channel: ch.id, atMs: Date.nowMs)
            guard !Task.isCancelled, channel?.id == ch.id else { return }
            if let cue, cue.key == item.key {
                tapeVolume = Float(cue.ambient)
                startOverlay(cue)
            } else {
                stopOverlay()
                if ch.audioOverlay == true { tapeVolume = 0 }
            }
        } else {
            stopOverlay()
        }
        guard let id = item.id, let url = await ArchiveMedia.resolve(id: id, file: item.file) else {
            guard !Task.isCancelled else { return }
            silenceTape()
            phase = .problem("This tape is missing from the Internet Archive. The next show starts at \(formatClock(item.endMs)).")
            return
        }
        guard !Task.isCancelled else { return }

        // Use a warmed asset if there is one (its header is already parsed); otherwise load the direct
        // storage address if an earlier warm found it, else archive.org/download. `url` stays the
        // canonical address: it is what the picture-fix lookup is keyed on.
        let warmed = warmer.take(url)
        warmer.cancelPending()   // nothing else may compete with this tape
        var asset = warmed?.asset ?? AVURLAsset(url: warmer.directURL(for: url) ?? url)
        var usedDirect = asset.url != url
        var wasWarm = warmed?.ready ?? false

        var playerItem = AVPlayerItem(asset: asset)
        var issuedMs = Date.nowMs
        var earlySeek: AsyncStream<Bool>?
        var ready = false
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        for attempt in 0..<2 {
            if attempt > 0 { playerItem = AVPlayerItem(asset: asset) }
            playerItem.preferredForwardBufferDuration = 8
            phase = .tuning
            clearPicture()
            tapeURL = url
            video.isMuted = true   // nothing is heard until the picture is shown
            video.replaceCurrentItem(with: playerItem)
            video.volume = tapeVolume

            // Ask for the broadcast position straight away, before the item is ready, with a lenient
            // tolerance (an exact seek has to decode from the keyframe before it). If AVFoundation
            // doesn't honour a seek this early, it is repeated once the item is ready.
            issuedMs = Date.nowMs
            let target = item.expectedPosition(atMs: issuedMs) + (wasWarm ? warmStartLag : coldStartLag)
            earlySeek = beginSeek(on: playerItem, to: target, tolerance: tolerance)

            ready = await waitUntilReady(playerItem, timeout: usedDirect ? 12 : 25)
            guard !Task.isCancelled else { return }
            if ready || !usedDirect { break }
            // The direct storage address didn't work: go back to archive.org/download for this item.
            playerItem.cancelPendingSeeks()
            warmer.forgetServer(for: url)
            asset = AVURLAsset(url: url)
            usedDirect = false
            wasWarm = false
        }
        guard ready else {
            silenceTape()
            phase = .problem("This tape won't play on Apple TV. The next show starts at \(formatClock(item.endMs)).")
            return
        }

        observeEnd(of: playerItem, scheduled: item)
        videoSize = playerItem.presentationSize
        refreshCorrection()
        matchDisplay(to: playerItem, key: item.key)

        var positioned = false
        if let earlySeek { positioned = await finished(earlySeek, within: 8) }
        guard !Task.isCancelled, video.currentItem === playerItem else { return }
        if !positioned {
            playerItem.cancelPendingSeeks()
            let recovered = await seekToBroadcast(item, tolerance: tolerance)
            guard !Task.isCancelled, video.currentItem === playerItem else { return }
            guard recovered else {
                silenceTape()
                phase = .problem("This tape couldn't reach its broadcast position. The next show starts at \(formatClock(item.endMs)).")
                return
            }
        }

        // Start at once: don't wait for the buffer to fill (later stalls still rebuffer normally).
        video.playImmediately(atRate: 1)
        await waitUntilPlaying(video, timeout: 3)
        guard !Task.isCancelled, video.currentItem === playerItem else { return }

        // Next tune from a similar kind of load starts further ahead by what this one really took.
        let took = (Date.nowMs - issuedMs) / 1000
        if wasWarm {
            warmStartLag = min(5, max(0.2, (warmStartLag + took) / 2))
        } else {
            coldStartLag = min(15, max(0.5, (coldStartLag + took) / 2))
        }

        // Check the sync once. Off by more than 0.3 s: one exact seek, which lands in data that is
        // already buffered, while the static is still up and the sound still off.
        if video.timeControlStatus == .playing {
            let drift = video.currentTime().seconds - item.expectedPosition(atMs: Date.nowMs)
            if abs(drift) > 0.3 {
                await seekToBroadcast(item)
                guard !Task.isCancelled, video.currentItem === playerItem else { return }
                video.playImmediately(atRate: 1)
                await waitUntilPlaying(video, timeout: 2)
                guard !Task.isCancelled, video.currentItem === playerItem else { return }
            }
        }
        video.isMuted = false
        phase = .playing
        scheduleWarms(delay: 1.5)
    }

    // MARK: - Warming

    /// Works out which tapes are worth warming (the next tape on this channel when it is close or when
    /// a commercial or card is on, plus what is on the channels above and below) and hands them to the warmer.
    private func scheduleWarms(delay: Double = 0) {
        warmTask?.cancel()
        warmLeadTask?.cancel()
        guard let ch = channel, let item = onAir else { return }
        let key = item.key
        let left = item.secondsLeft(atMs: Date.nowMs)
        // A show: wake up 60 s before it ends to warm what follows it.
        if item.type == "video", left > 60 {
            warmLeadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(left - 60))
                guard !Task.isCancelled, let self, self.channel?.id == ch.id, self.onAir?.key == key else { return }
                self.scheduleWarms()
            }
        }
        let includeNext = item.type != "video" || left <= 60
        warmTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await self?.updateWarms(channel: ch, item: item, includeNext: includeNext)
        }
    }

    private func updateWarms(channel ch: ChannelInfo, item: OnAir, includeNext: Bool) async {
        guard !Task.isCancelled, let store, let engine = store.engine else { return }
        func stillCurrent() -> Bool { !Task.isCancelled && channel?.id == ch.id && onAir?.key == item.key }
        guard stillCurrent() else { return }

        var targets: [OnAir] = []
        if includeNext, let next = await nextTape(after: item.endMs, on: ch.id, engine: engine) {
            targets.append(next)
        }
        let list = store.watchableChannels
        if list.count > 1, let index = list.firstIndex(where: { $0.id == ch.id }) {
            // Same order as PlayerScreen.changeChannel: up is +1, down is -1, both wrap around.
            let up = list[(index + 1) % list.count]
            let down = list[(index - 1 + list.count) % list.count]
            for neighbour in (up.id == down.id ? [up] : [up, down]) {
                guard stillCurrent() else { return }
                if let onNow = await engine.onAir(channel: neighbour.id, atMs: Date.nowMs) {
                    if onNow.isTape { targets.append(onNow) }
                    else if let next = await nextTape(after: onNow.endMs, on: neighbour.id, engine: engine) { targets.append(next) }
                }
            }
        }
        guard stillCurrent() else { return }

        var urls: [URL] = []
        for t in targets {
            // A very large moov atom (over 8 MB) takes seconds to fetch: not worth warming speculatively.
            if let moov = t.moov, moov > 8_000_000 { continue }
            guard let id = t.id, let url = ArchiveMedia.canonicalURL(id: id, file: t.file),
                  url != tapeURL, !urls.contains(url) else { continue }
            urls.append(url)
        }
        warmer.setWanted(urls)
    }

    /// The first tape that starts at or after `ms` on a channel, skipping cards and station breaks.
    private func nextTape(after ms: Double, on channelID: String, engine: ScheduleEngine) async -> OnAir? {
        var at = ms + 30
        for _ in 0..<4 {
            guard !Task.isCancelled, let found = await engine.onAir(channel: channelID, atMs: at) else { return nil }
            if found.isTape { return found }
            at = found.endMs + 30
        }
        return nil
    }

    func setFullscreen(_ visible: Bool) {
        fullscreen = visible
        displayTask?.cancel()
        if visible, let item = video.currentItem, item.status == .readyToPlay, let key = onAir?.key {
            matchDisplay(to: item, key: key)
        } else if !visible {
            DisplayMatching.reset()
        }
    }

    /// Asks the TV to match the tape's frame rate and dynamic range (Match Content settings).
    /// Runs alongside playback so it never delays the start, and is dropped if the tape has changed.
    private func matchDisplay(to playerItem: AVPlayerItem, key: String) {
        guard fullscreen, DisplayMatching.isEnabled else { return }
        displayTask?.cancel()
        let asset = playerItem.asset
        displayTask = Task { [weak self] in
            let target = await DisplayMatching.target(for: asset)
            guard !Task.isCancelled, let self, self.fullscreen, self.onAir?.key == key,
                  self.video.currentItem === playerItem else { return }
            if let target { DisplayMatching.apply(target) } else { DisplayMatching.reset() }
        }
    }

    /// Stops whatever tape or card music was on, so a problem screen is never silent-but-wrong
    /// (an earlier tape carrying on under a "can't play" card).
    private func silenceTape(resetDisplay: Bool = true) {
        stopObservingEnd()
        displayTask?.cancel()
        if resetDisplay { DisplayMatching.reset() }
        stopOverlay()
        stopHum()
        isBuffering = false
        video.currentItem?.cancelPendingSeeks()
        video.pause()
        video.replaceCurrentItem(with: nil)
        video.isMuted = false
        music.pause()
        music.replaceCurrentItem(with: nil)
        clearPicture()
    }

    // MARK: - Picture corrections

    /// Looks the tape up in spelunkr.tv's stretch / zoom maps. Called again while playing, in case
    /// the maps finish downloading after the tape starts.
    private func refreshCorrection() {
        guard let url = tapeURL, let fixes = store?.aspectFixes else { return }
        let wanted = fixes.correction(for: url)
        if wanted != correction { correction = wanted }
    }

    private func clearPicture() {
        tapeURL = nil
        if !correction.isNone { correction = .none }
        if videoSize != .zero { videoSize = .zero }
    }

    /// Seek to where the broadcast is now, allowing for how long the seek itself takes.
    /// Exact by default; the first seek of a tune passes a tolerance so it can land on a nearby frame sooner.
    /// Returns whether the seek ran to completion (false if something interrupted it).
    @discardableResult
    private func seekToBroadcast(_ item: OnAir, tolerance: CMTime = .zero) async -> Bool {
        let started = Date.nowMs
        let target = item.expectedPosition(atMs: Date.nowMs) + seekLag
        guard let playerItem = video.currentItem else { return false }
        let seek = beginSeek(on: playerItem, to: target, tolerance: tolerance)
        let done = await finished(seek, within: 8)
        guard !Task.isCancelled, video.currentItem === playerItem else { return false }
        if !done { playerItem.cancelPendingSeeks() }
        let took = (Date.nowMs - started) / 1000
        seekLag = min(5, max(0.2, (seekLag + took) / 2))
        lastCorrectionMs = Date.nowMs
        return done
    }

    /// Waits (by observing `status`, no polling) until the item is ready or has failed, or the timeout passes.
    private func waitUntilReady(_ item: AVPlayerItem, timeout: Double) async -> Bool {
        if item.status == .unknown {
            let statuses = item.publisher(for: \.status)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await status in statuses.values where status != .unknown { return }
                }
                group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        return !Task.isCancelled && item.status == .readyToPlay
    }

    /// Waits until the player reports that it is playing, for at most `timeout` seconds.
    private func waitUntilPlaying(_ player: AVPlayer, timeout: Double) async {
        guard player.timeControlStatus != .playing else { return }
        let statuses = player.publisher(for: \.timeControlStatus)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await status in statuses.values where status == .playing { return }
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func beginSeek(on playerItem: AVPlayerItem, to seconds: Double, tolerance: CMTime) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            playerItem.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                            toleranceBefore: tolerance, toleranceAfter: tolerance) { completed in
                continuation.yield(completed)
                continuation.finish()
            }
        }
    }

    /// The outcome of a seek that is already under way, or false if it hasn't finished within `seconds`.
    private func finished(_ seek: AsyncStream<Bool>, within seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await result in seek { return result }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func playMusic(for item: OnAir, base: URL) async {
        guard let audio = item.audio else {
            music.pause()
            return
        }
        let url = base.appendingPathComponent(audio.filename)
        let musicItem = AVPlayerItem(url: url)
        music.replaceCurrentItem(with: musicItem)
        guard await waitUntilReady(musicItem, timeout: 6), !Task.isCancelled, onAir?.key == item.key else { return }
        let position = (audio.startOffset ?? 0) + max(0, (Date.nowMs - item.startMs) / 1000)
        _ = await music.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        guard !Task.isCancelled, onAir?.key == item.key else { return }
        music.play()
    }

    // MARK: - Overlay music

    /// Starts the music for a tape and arranges to switch tracks when the playlist moves on.
    private func startOverlay(_ cue: OverlayCue) {
        stopOverlay()
        overlayCue = cue
        overlayRecovered = nil
        overlayTask = Task { [weak self] in await self?.playOverlay(cue) }
        guard let nextAt = cue.nextAtMs else { return }
        // Never spin: even if the schedule names a changeover that is already past, ask at most 4 times a second.
        let wait = max(0.25, (nextAt - Date.nowMs) / 1000)
        overlayBoundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let ch = self.channel, let engine = self.store?.engine else { return }
            // Ask a moment after the changeover so we get the new track even if we woke early.
            let at = max(Date.nowMs, nextAt) + 20
            let next = await engine.overlay(channel: ch.id, atMs: at)
            guard !Task.isCancelled, self.channel?.id == ch.id, self.overlayCue == cue else { return }
            if let next, self.onAir?.key == next.key {
                self.startOverlay(next)
            } else {
                self.stopOverlay()
            }
        }
    }

    private func stopOverlay() {
        overlayTask?.cancel(); overlayTask = nil
        overlayBoundaryTask?.cancel(); overlayBoundaryTask = nil
        overlayCue = nil
        overlayIsStandIn = false
        overlay.pause()
        overlay.replaceCurrentItem(with: nil)
    }

    /// Loads the cue's track and joins it where the broadcast is now. If it won't play, tries the
    /// stand-ins in order (they start from the top, like on the site).
    private func playOverlay(_ cue: OverlayCue, skippingTrack: Bool = false) async {
        guard let track = cue.track else {
            overlay.pause()
            overlay.replaceCurrentItem(with: nil)
            return
        }
        var candidates = Array(([track] + cue.fallbacks).prefix(4))
        if skippingTrack { candidates.removeFirst() }
        for (index, candidate) in candidates.enumerated() {
            let n = skippingTrack ? index + 1 : index
            guard let url = await ArchiveMedia.resolveAudio(id: candidate.id, file: candidate.file, url: candidate.url) else { continue }
            guard !Task.isCancelled, overlayCue == cue else { return }
            let item = AVPlayerItem(url: url)
            overlay.replaceCurrentItem(with: item)
            overlayIsStandIn = n > 0
            guard await waitUntilReady(item, timeout: 10) else {
                if Task.isCancelled { return }
                continue
            }
            guard !Task.isCancelled, overlayCue == cue else { return }
            let started = Date.nowMs
            let target = n == 0 ? cue.position(atMs: started) + overlayLag : 0
            overlay.volume = 1
            if target > 0 {
                _ = await overlay.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                       toleranceBefore: .zero, toleranceAfter: .zero)
                let took = (Date.nowMs - started) / 1000
                overlayLag = min(3, max(0.1, (overlayLag + took) / 2))
            }
            guard !Task.isCancelled, overlayCue == cue else { return }
            overlay.play()
            overlayCorrectionMs = Date.nowMs
            return
        }
    }

    /// Keeps the music on the broadcast clock, like the tape: re-seeks if it has drifted (after a stall).
    private func checkOverlay() {
        // The track went bad after it started: move to a stand-in, as the site does.
        if let cue = overlayCue, cue.track != nil, overlayRecovered != cue,
           overlay.currentItem?.status == .failed {
            overlayRecovered = cue
            overlayTask?.cancel()
            overlayTask = Task { [weak self] in await self?.playOverlay(cue, skippingTrack: true) }
            return
        }
        guard let cue = overlayCue, cue.track != nil, !overlayIsStandIn,
              overlay.currentItem?.status == .readyToPlay,
              overlay.timeControlStatus == .playing,
              Date.nowMs - overlayCorrectionMs > 15_000 else { return }
        let now = Date.nowMs
        let drift = overlay.currentTime().seconds - cue.position(atMs: now)
        guard abs(drift) > 1.5 else { return }
        overlayCorrectionMs = now
        let target = cue.position(atMs: now) + overlayLag
        Task { [weak self] in
            guard let self, self.overlayCue == cue else { return }
            _ = await self.overlay.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func startHum() {
        guard humLooper == nil else {
            if hum.timeControlStatus == .paused { hum.play() }
            return
        }
        guard let url = URL(string: "https://spelunkr.tv/audio/ambient/projector-hum.mp3") else { return }
        humLooper = AVPlayerLooper(player: hum, templateItem: AVPlayerItem(url: url))
        hum.play()
    }

    private func stopHum() {
        hum.pause()
        humLooper?.disableLooping()
        humLooper = nil
        hum.removeAllItems()
    }

    /// When the current item ends, tune again to pick up the next one.
    private func scheduleBoundary(atMs endMs: Double) {
        boundaryTask?.cancel()
        // A few ms past the end, so a wake-up that is slightly early can't land on the same item again.
        let wait = max(0.05, (endMs - Date.nowMs) / 1000 + 0.03)
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let ch = self.channel else { return }
            self.tune(ch)
        }
    }

    private func observeEnd(of playerItem: AVPlayerItem, scheduled item: OnAir) {
        stopObservingEnd()
        let ended = AVPlayerItem.didPlayToEndTimeNotification
        for name in [ended, AVPlayerItem.failedToPlayToEndTimeNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: playerItem, queue: .main
            ) { [weak self, weak playerItem] _ in
                Task { @MainActor in
                    guard let self, let playerItem, self.video.currentItem === playerItem,
                          let channel = self.channel else { return }
                    if Date.nowMs >= item.endMs {
                        self.tune(channel)
                    } else {
                        self.tuneTask?.cancel()
                        self.silenceTape()
                        let reason = name == ended ? "This tape ended." : "This tape stopped playing."
                        self.phase = .problem("\(reason) The next show starts at \(formatClock(item.endMs)).")
                    }
                }
            }
            endObservers.append(observer)
        }
    }

    private func stopObservingEnd() {
        for observer in endObservers { NotificationCenter.default.removeObserver(observer) }
        endObservers.removeAll()
    }

    /// Watches for buffering and quietly re-syncs if playback drifts from the broadcast.
    private func startMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.checkPlayback()
            }
        }
    }

    private func checkPlayback() {
        checkOverlay()
        if case .playing = phase, let current = video.currentItem {
            if videoSize == .zero, current.presentationSize != .zero { videoSize = current.presentationSize }
            refreshCorrection()
        }
        guard case .playing = phase, let item = onAir, item.isTape, let current = video.currentItem else {
            isBuffering = false
            return
        }
        if current.status == .failed {
            silenceTape()
            phase = .problem("This tape stopped playing. The next show starts at \(formatClock(item.endMs)).")
            return
        }
        isBuffering = video.timeControlStatus == .waitingToPlayAtSpecifiedRate
        // Only while it is really playing: a tape that ended early sits paused at its last frame,
        // and seeking it again would achieve nothing.
        guard !isBuffering, video.timeControlStatus == .playing, Date.nowMs - lastCorrectionMs > 20_000 else { return }
        let drift = video.currentTime().seconds - item.expectedPosition(atMs: Date.nowMs)
        if abs(drift) > 3 {
            lastCorrectionMs = Date.nowMs
            Task { [weak self] in
                // Don't seek whatever is loaded now to the position of a tape that has since changed.
                guard let self, self.onAir?.key == item.key, case .playing = self.phase else { return }
                await self.seekToBroadcast(item)
            }
        }
    }
}

/// Builds Internet Archive download URLs the same way spelunkr.tv does.
enum ArchiveMedia {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    /// Same as JavaScript's encodeURIComponent.
    static func encodeComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// The canonical download address for a tape whose file name is known (nil if it isn't).
    static func canonicalURL(id: String, file: String?) -> URL? {
        guard let file, !file.isEmpty else { return nil }
        return URL(string: "https://archive.org/download/\(id)/\(encodeComponent(file))")
    }

    static func resolve(id: String, file: String?) async -> URL? {
        if let url = canonicalURL(id: id, file: file) { return url }
        return await lookUpVideoFile(id: id)
    }

    /// Plain http is blocked by App Transport Security, so addresses that come from schedule data
    /// are upgraded to https (same host and path) before they are used.
    static func secure(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url ?? url
    }

    /// Address of an overlay-music file. The schedule gives the full address when it can; otherwise
    /// it is built from the item id and file name, or picked from the item's metadata (MP3 first).
    static func resolveAudio(id: String, file: String?, url: String?) async -> URL? {
        if let url, let u = URL(string: url) { return secure(u) }
        if let file, !file.isEmpty {
            let path = file.split(separator: "/", omittingEmptySubsequences: false).map { encodeComponent(String($0)) }.joined(separator: "/")
            return URL(string: "https://archive.org/download/\(id)/\(path)")
        }
        return await lookUpAudioFile(id: id)
    }

    private static func lookUpAudioFile(id: String) async -> URL? {
        guard let url = URL(string: "https://archive.org/metadata/\(id)"),
              let result = try? await URLSession.shared.data(from: url),
              let meta = try? JSONDecoder().decode(Metadata.self, from: result.0) else { return nil }
        let files = meta.files ?? []
        let pick = files.first { $0.format == "VBR MP3" }
            ?? files.first { $0.format == "128Kbps MP3" }
            ?? files.first { $0.format == "64Kbps MP3" }
            ?? files.first { $0.name.hasSuffix(".mp3") }
        guard let pick else { return nil }
        return URL(string: "https://archive.org/download/\(id)/\(encodeComponent(pick.name))")
    }

    private struct Metadata: Decodable {
        struct File: Decodable { let name: String; let format: String? }
        let files: [File]?
    }

    /// For the rare item with no file named in the schedule: pick an MP4 from the item's metadata.
    private static func lookUpVideoFile(id: String) async -> URL? {
        guard let url = URL(string: "https://archive.org/metadata/\(id)"),
              let result = try? await URLSession.shared.data(from: url),
              let meta = try? JSONDecoder().decode(Metadata.self, from: result.0) else { return nil }
        let files = meta.files ?? []
        let pick = files.first { ($0.format ?? "").localizedCaseInsensitiveContains("h.264") }
            // "512Kb MPEG4" is MPEG-4 Part 2, which AVPlayer can't play.
            ?? files.first {
                let f = $0.format ?? ""
                return f.localizedCaseInsensitiveContains("mpeg4") && !f.localizedCaseInsensitiveContains("512Kb")
            }
            ?? files.first { $0.name.lowercased().hasSuffix(".mp4") }
        guard let pick else { return nil }
        return URL(string: "https://archive.org/download/\(id)/\(encodeComponent(pick.name))")
    }
}
