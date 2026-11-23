import SwiftUI

/// Web-style WeatherStar 4000 guide home screen:
/// - Top left: live preview window with channel down/up controls and SPELUNKR.TV badge.
/// - Top right: channel & show info panel (logomark, family tag, LIVE, viewers, blurb, progress bar, UP NEXT, WATCH / VIEW CHANNEL).
/// - Bottom: shared 3-hour `GuideGrid`.
struct GuideHome: View {
    @Environment(BroadcastStore.self) private var store
    @Binding var selectedChannel: ChannelInfo?
    let onWatch: (ChannelInfo) -> Void

    @State private var inspectedBlock: GuideBlock?
    @State private var windowStartMs: Double = GuideGrid.currentHalfHourMs()
    @State private var scheduleSheetChannel: ChannelInfo?
    @State private var previewDebounceTask: Task<Void, Never>?

    private var activeChannel: ChannelInfo? {
        store.channels.first { $0.id == selectedChannel?.id } ?? store.watchableChannels.first ?? store.channels.first
    }

    var body: some View {
        VStack(spacing: 16) {
            if let warning = store.engineWarning {
                Text(warning)
                    .font(Theme.label(16))
                    .foregroundStyle(Theme.yellow)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.25))
                    .overlay(Rectangle().stroke(Color.orange, lineWidth: 1))
            }

            // Top section: Live preview (left) + Info panel (right), aligned flush at 404pt tall
            HStack(alignment: .top, spacing: 20) {
                previewPane
                    .frame(width: 620, height: 404)

                infoPanel
                    .frame(maxWidth: .infinity, minHeight: 404, maxHeight: 404)
            }

            // Bottom section: 3-hour time grid
            GuideGrid(
                selectedChannel: $selectedChannel,
                inspectedBlock: $inspectedBlock,
                windowStartMs: $windowStartMs,
                onWatch: watch
            )
            .frame(maxHeight: .infinity)
        }
        // tvOS title-safe margins
        .padding(.horizontal, 60)
        .padding(.vertical, 44)
        .background(Theme.screenBackground.ignoresSafeArea())
        .onAppear {
            if selectedChannel == nil, let first = store.watchableChannels.first {
                selectedChannel = first
                schedulePreviewTune(for: first, immediate: true)
            } else if let current = activeChannel {
                schedulePreviewTune(for: current, immediate: store.tv.channel == nil)
            }
        }
        .onChange(of: selectedChannel?.id) { _, _ in
            if let ch = activeChannel {
                schedulePreviewTune(for: ch, immediate: false)
            }
        }
        .onDisappear { previewDebounceTask?.cancel() }
        .task(id: activeChannel.map(DetailsRequest.init)) {
            if let ch = activeChannel {
                await store.ensureDetails(for: ch)
            }
        }
        .fullScreenCover(item: $scheduleSheetChannel) { channel in
            ChannelScheduleSheet(channel: store.channels.first { $0.id == channel.id } ?? channel) {
                scheduleSheetChannel = nil
                watch(channel)
            } onClose: {
                scheduleSheetChannel = nil
            }
        }
    }

    // MARK: - Top Left: Live Preview

    private var previewPane: some View {
        let ch = activeChannel
        let tv = store.tv

        return VStack(spacing: 10) {
            SpelunkrPanel(borderColor: Theme.ringOuter) {
                ZStack {
                    Color.black

                    PlayerLayerView(player: tv.video, correction: tv.correction, videoSize: tv.videoSize)
                        .opacity(tv.phase == .playing ? 1 : 0)

                    switch tv.phase {
                    case .idle, .tuning:
                        previewTuningOverlay(channel: ch, caption: "TUNING…")
                    case .card:
                        if let item = tv.onAir, let playingCh = tv.channel {
                            BumpCardView(item: item, channel: playingCh)
                        }
                    case .problem(let message):
                        previewTuningOverlay(channel: ch, caption: message)
                    case .playing:
                        EmptyView()
                    }
                }
                .frame(width: 616, height: 346)
                .clipped()
            }

            // Channel stepper bar below preview
            HStack(spacing: 12) {
                Button {
                    stepChannel(by: -1)
                } label: {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(SpelunkrActionButtonStyle(
                    background: AnyShapeStyle(Theme.panelBox),
                    restingBorder: Theme.borderLight,
                    horizontalPadding: 14,
                    verticalPadding: 10
                ))

                Text(ch.map { "CH \($0.dialText)" } ?? "CH --")
                    .font(Theme.dialNumber(28))
                    .foregroundStyle(Theme.yellow)
                    .wsShadow()
                    .frame(minWidth: 106)

                Button {
                    stepChannel(by: 1)
                } label: {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(SpelunkrActionButtonStyle(
                    background: AnyShapeStyle(Theme.panelBox),
                    restingBorder: Theme.borderLight,
                    horizontalPadding: 14,
                    verticalPadding: 10
                ))

                Spacer()

                Text("SPELUNKR.TV")
                    .font(Theme.heading(24))
                    .foregroundStyle(Theme.softText)
                    .wsShadow()
            }
            .padding(.horizontal, 4)
        }
    }

    private func previewTuningOverlay(channel: ChannelInfo?, caption: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [Theme.deepNavy, Theme.brandPurple.opacity(0.95), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 12) {
                if let rows = channel?.logomark?.rows, !rows.isEmpty {
                    LogomarkView(rows: rows, primaryColor: channel?.color, size: 64)
                }
                if let channel {
                    Text("CH \(channel.dialText) - \(channel.name)")
                        .font(Theme.channelName(24))
                        .foregroundStyle(Theme.yellow)
                        .wsShadow()
                        .lineLimit(1)
                }
                Text(caption)
                    .font(Theme.label(18))
                    .foregroundStyle(Theme.cyan)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Top Right: Info Panel

    private var infoPanel: some View {
        let ch = activeChannel
        let _ = store.detailsRevision // observe details loads

        return SpelunkrPanel(borderColor: Theme.ringOuter) {
            if let ch {
                let entries = store.guide[ch.id] ?? []
                let viewers = store.presence.count(for: ch.id)

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let nowMs = Date.nowMs
                    let liveItem = (store.tv.channel?.id == ch.id) ? store.tv.onAir : nil
                    let currentEntry = entries.first { $0.startMs <= nowMs && nowMs < $0.endMs }
                    let upcoming = entries.filter { $0.startMs > nowMs }.prefix(2)
                    let program: (title: String, year: String?, version: Int?, index: Int?, start: Double, end: Double) = {
                        if let block = inspectedBlock {
                            return (block.isMarathon ? block.marathonHeadline(channelName: ch.name) : block.title,
                                       block.year, block.version, block.videoIndex, block.startMs, block.endMs)
                        } else if let liveItem, liveItem.type == "video" || currentEntry == nil {
                            return (liveItem.displayTitle, liveItem.year, liveItem.version, liveItem.videoIndex,
                                       liveItem.startMs, liveItem.endMs)
                        } else if let currentEntry {
                            return (currentEntry.title, currentEntry.year, currentEntry.version, currentEntry.videoIndex,
                                       currentEntry.startMs, currentEntry.endMs)
                        } else {
                            return ("Station break", nil, nil, nil, nowMs, nowMs)
                        }
                    }()
                    let blurb = store.detail(channelID: ch.id, version: program.version, videoIndex: program.index)?.description
                    let startMs = program.start
                    let endMs = program.end
                    let totalS = max(1, (endMs - startMs) / 1000)
                    let elapsedS = max(0, min(totalS, (nowMs - startMs) / 1000))
                    let remainingS = max(0, (endMs - nowMs) / 1000)
                    let progress = inspectedBlock == nil ? (elapsedS / totalS) : 0

                    VStack(alignment: .leading, spacing: 10) {
                        // Channel identity & LIVE/viewers row
                        HStack(spacing: 12) {
                            if let rows = ch.logomark?.rows, !rows.isEmpty {
                                LogomarkView(rows: rows, primaryColor: ch.color, size: 44)
                            } else {
                                Text(ch.emoji ?? "📺").font(.system(size: 30))
                            }

                            Text(ch.name)
                                .font(Theme.channelName(28))
                                .foregroundStyle(Theme.yellow)
                                .lineLimit(1)
                                .wsShadow()

                            if let family = ch.family, !family.isEmpty {
                                FamilyBadge(family: family)
                            }

                            Text("CH \(ch.dialText)")
                                .font(Theme.label(18))
                                .foregroundStyle(Theme.softText)

                            Spacer()

                            LiveBadge()
                            if viewers > 0 {
                                ViewerBadge(count: viewers, suffix: "WATCHING", fontSize: 17, color: Theme.softText)
                            }
                        }

                        if let desc = ch.description, !desc.isEmpty {
                            Text(desc)
                                .font(Theme.body(19))
                                .foregroundStyle(Theme.blueMuted)
                                .lineLimit(2)
                        }

                        // NOW PLAYING / INSPECTED
                        VStack(alignment: .leading, spacing: 4) {
                            Text(inspectedBlock.map { "SCHEDULED - \(Theme.formatTime12($0.startMs))" } ?? "NOW PLAYING")
                                .font(Theme.label(16))
                                .foregroundStyle(Theme.yellow)

                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(program.title)
                                    .font(Theme.heading(34))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .wsShadow()

                                if let displayYear = program.year, !displayYear.isEmpty {
                                    Text(displayYear)
                                        .font(Theme.label(22))
                                        .foregroundStyle(Theme.cyan)
                                }
                            }

                            if let blurb, !blurb.isEmpty {
                                Text(blurb)
                                    .font(Theme.body(19))
                                    .foregroundStyle(Theme.softText)
                                    .lineLimit(2)
                            } else if let inspected = inspectedBlock, inspected.isMarathon {
                                Text("\(inspected.showCount) shows - \(inspected.spanText)")
                                    .font(Theme.body(19))
                                    .foregroundStyle(Theme.cyan)
                            }
                        }

                        // Progress bar
                        if inspectedBlock == nil {
                            SpelunkrProgressBar(
                                progress: progress,
                                elapsedText: formatDuration(elapsedS),
                                remainingText: "\(formatDuration(remainingS)) LEFT"
                            )
                        }

                        Spacer(minLength: 4)

                        // Bottom bar: UP NEXT (left) + WATCH / VIEW CHANNEL buttons (right)
                        HStack(alignment: .bottom, spacing: 20) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("UP NEXT")
                                    .font(Theme.label(15))
                                    .foregroundStyle(Theme.blueMuted)

                                ForEach(Array(upcoming), id: \.startMs) { next in
                                    HStack(spacing: 12) {
                                        Text(Theme.formatTime12(next.startMs))
                                            .font(Theme.label(18))
                                            .foregroundStyle(Theme.yellow)
                                            .frame(width: 112, alignment: .leading)
                                        Text(next.title)
                                            .font(Theme.body(19))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 14) {
                                Button {
                                    watch(ch)
                                } label: {
                                    Text("WATCH")
                                        .font(Theme.button(22))
                                        .foregroundStyle(.white)
                                        .wsShadow()
                                }
                                .buttonStyle(SpelunkrActionButtonStyle(
                                    background: AnyShapeStyle(Theme.watchOrangeGradient),
                                    restingBorder: Theme.yellow,
                                    horizontalPadding: 28,
                                    verticalPadding: 13
                                ))
                                .disabled(!ch.isWatchable)

                                Button {
                                    scheduleSheetChannel = ch
                                } label: {
                                    Text("VIEW CHANNEL")
                                        .font(Theme.button(22))
                                        .foregroundStyle(.white)
                                        .wsShadow()
                                }
                                .buttonStyle(SpelunkrActionButtonStyle(
                                    background: AnyShapeStyle(Theme.viewChannelBlueGradient),
                                    restingBorder: Theme.borderLight,
                                    horizontalPadding: 24,
                                    verticalPadding: 13
                                ))
                            }
                        }
                    }
                    .padding(20)
                }
            } else {
                Text("Select a channel")
                    .font(Theme.body(22))
                    .foregroundStyle(Theme.softText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Preview Tuning & Channel Stepping

    private func watch(_ channel: ChannelInfo) {
        guard channel.isWatchable else { return }
        previewDebounceTask?.cancel()
        onWatch(channel)
    }

    private func schedulePreviewTune(for channel: ChannelInfo, immediate: Bool) {
        previewDebounceTask?.cancel()
        guard channel.isWatchable else { return }
        if store.tv.channel?.id == channel.id {
            store.presence.track(channelID: channel.id)
            return
        }
        previewDebounceTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, activeChannel?.id == channel.id else { return }
            store.tv.tune(channel)
            store.presence.track(channelID: channel.id)
        }
    }

    private func stepChannel(by delta: Int) {
        let list = store.watchableChannels
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == activeChannel?.id } ?? 0
        let next = list[(idx + delta + list.count) % list.count]
        selectedChannel = next
        inspectedBlock = nil
    }
}

// MARK: - Full Channel Schedule Sheet (VIEW CHANNEL)

private struct DetailsRequest: Equatable {
    let id: String
    let versions: [VersionPointer]

    init(_ channel: ChannelInfo) {
        id = channel.id
        versions = channel.versions
    }
}

private struct ChannelScheduleSheet: View {
    @Environment(BroadcastStore.self) private var store
    let channel: ChannelInfo
    let onWatch: () -> Void
    let onClose: () -> Void

    @State private var programs: [GuideProgram] = []

    var body: some View {
        let _ = store.detailsRevision

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                if let rows = channel.logomark?.rows, !rows.isEmpty {
                    LogomarkView(rows: rows, primaryColor: channel.color, size: 54)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text("CH \(channel.dialText)")
                            .font(Theme.dialNumber(30))
                            .foregroundStyle(Theme.yellow)
                        Text(channel.name)
                            .font(Theme.channelName(30))
                            .foregroundStyle(.white)
                        if let fam = channel.family { FamilyBadge(family: fam) }
                    }
                    if let desc = channel.description {
                        Text(desc)
                            .font(Theme.body(19))
                            .foregroundStyle(Theme.blueMuted)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button {
                    onWatch()
                } label: {
                    Text("WATCH LIVE")
                        .font(Theme.button(20))
                        .foregroundStyle(.white)
                        .wsShadow()
                }
                .buttonStyle(SpelunkrActionButtonStyle(
                    background: AnyShapeStyle(Theme.watchOrangeGradient),
                    restingBorder: Theme.yellow,
                    horizontalPadding: 24,
                    verticalPadding: 12
                ))
                .disabled(!channel.isWatchable)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(programs) { program in
                        let now = Date.nowMs
                        let airing = program.isAiring(atMs: now)
                        let blurb = store.detail(channelID: channel.id, version: program.version, videoIndex: program.videoIndex)?.description

                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Theme.formatTime12(program.startMs))
                                    .font(Theme.label(20))
                                    .foregroundStyle(Theme.yellow)
                                Text(formatDuration(program.durationS))
                                    .font(Theme.label(16))
                                    .foregroundStyle(Theme.blueMuted)
                            }
                            .frame(width: 140, alignment: .leading)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 10) {
                                    if airing { LiveBadge() }
                                    Text(program.title)
                                        .font(Theme.heading(24))
                                        .foregroundStyle(.white)
                                    if let year = program.year {
                                        Text(year)
                                            .font(Theme.label(18))
                                            .foregroundStyle(Theme.cyan)
                                    }
                                }
                                if let blurb, !blurb.isEmpty {
                                    Text(blurb)
                                        .font(Theme.body(18))
                                        .foregroundStyle(Theme.softText)
                                        .lineLimit(3)
                                }
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(airing ? AnyShapeStyle(Theme.focusRowGradient) : AnyShapeStyle(Theme.panelBox.opacity(0.85)))
                        .overlay(Rectangle().stroke(airing ? Theme.yellow : Theme.ringOuter, lineWidth: airing ? 2 : 1))
                    }
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .background(Theme.screenBackground.ignoresSafeArea())
        .onExitCommand { onClose() }
        .task(id: DetailsRequest(channel)) {
            await store.ensureDetails(for: channel)
            let now = Date.nowMs
            programs = await store.programs(for: channel.id, fromMs: now, toMs: now + 24 * 3600 * 1000)
        }
    }
}
