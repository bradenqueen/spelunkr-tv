import SwiftUI

/// The guide home screen:
/// - Top left: live preview window with channel down/up controls and SPELUNKR.TV badge.
/// - Top right: channel and program information, playback actions, and Theme Mode.
/// - Bottom: shared 3-hour `GuideGrid`.
struct GuideHome: View {
    @Environment(\.appTheme) private var theme
    @Environment(BroadcastStore.self) private var store
    @Binding var selectedChannel: ChannelInfo?
    let onWatch: (ChannelInfo) -> Void

    @State private var inspectedBlock: GuideBlock?
    @State private var windowStartMs: Double = GuideGrid.currentHalfHourMs()
    @State private var presentation: Presentation?
    @State private var focusAfterDismissal: GuideFocus?
    @State private var hasAppeared = false
    @State private var previewDebounceTask: Task<Void, Never>?
    @State private var focusIntent: GuideGrid.FocusIntent?
    @FocusState private var focus: GuideFocus?

    private enum Presentation: Identifiable {
        case channelSchedule(ChannelInfo)
        case themePicker

        var id: String {
            switch self {
            case .channelSchedule(let channel): return "schedule-\(channel.id)"
            case .themePicker: return "theme-picker"
            }
        }
    }

    private var activeChannel: ChannelInfo? {
        store.channels.first { $0.id == selectedChannel?.id } ?? store.watchableChannels.first ?? store.channels.first
    }

    var body: some View {
        VStack(spacing: 12) {
            if let warning = store.engineWarning {
                Text(warning)
                    .font(theme.label(22))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.warningAccent.opacity(0.25), in: RoundedRectangle(cornerRadius: theme.controlCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.controlCornerRadius)
                            .strokeBorder(theme.warningAccent, lineWidth: 1)
                    }
            }

            // Top section: Live preview (left) + Info panel (right), aligned flush at 480pt tall
            // A focus section, so Down from any control here reaches the grid and Up from the grid reaches WATCH.
            HStack(alignment: .top, spacing: 20) {
                previewPane
                    .frame(width: 640, height: 480)

                infoPanel
                    .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
            }
            .focusSection()

            // Bottom section: 3-hour time grid
            GuideGrid(
                selectedChannel: $selectedChannel,
                inspectedBlock: $inspectedBlock,
                windowStartMs: $windowStartMs,
                focusIntent: $focusIntent,
                focus: $focus,
                onWatch: watch
            )
            .frame(maxHeight: .infinity)
            .focusSection()
        }
        // tvOS title-safe margins (80 pt left/right, 60 pt top/bottom). Height at 1080:
        // 60 + 480 (top) + 12 + 468 (grid: 50 header + 418 rows) + 60 = 1080.
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .background(theme.screenBackground.ignoresSafeArea())
        .onAppear {
            // A cover can hide and reveal this guide without replacing its state.
            guard !hasAppeared else { return }
            hasAppeared = true
            if selectedChannel == nil, let first = store.watchableChannels.first {
                selectedChannel = first
                schedulePreviewTune(for: first, immediate: true)
            } else if let current = activeChannel {
                schedulePreviewTune(for: current, immediate: store.tv.channel == nil)
            }
            // Start on the grid: the cell airing now on the current / last-watched channel.
            if let current = activeChannel, current.isWatchable {
                focusIntent = GuideGrid.FocusIntent(channelID: current.id, atMs: Date.nowMs)
            }
        }
        .onChange(of: selectedChannel?.id) { _, _ in
            if let ch = activeChannel {
                schedulePreviewTune(for: ch, immediate: false)
            }
        }
        .onDisappear {
            if presentation == nil { previewDebounceTask?.cancel() }
        }
        .task(id: activeChannel.map(DetailsRequest.init)) {
            if let ch = activeChannel {
                await store.ensureDetails(for: ch)
            }
        }
        .fullScreenCover(item: $presentation, onDismiss: restoreGuideFocus) { presented in
            switch presented {
            case .channelSchedule(let channel):
                ChannelScheduleSheet(channel: store.channels.first { $0.id == channel.id } ?? channel) {
                    focusAfterDismissal = nil
                    presentation = nil
                    watch(channel)
                } onClose: {
                    presentation = nil
                }
            case .themePicker:
                ThemePicker {
                    presentation = nil
                }
            }
        }
    }

    // MARK: - Top Left: Live Preview

    private var previewPane: some View {
        let ch = activeChannel
        let tv = store.tv
        // The preview is only valid for the highlighted channel; between a row change and the retune
        // it must not show the previous channel's last frame.
        let isTunedToChannel = ch != nil && tv.channel?.id == ch?.id

        // Keep the same video and control area across themes.
        let borderWidth = theme.panelBorderWidth + theme.panelInnerBorderWidth
        return VStack(spacing: 0) {
            ZStack {
                Color.black

                PlayerLayerView(player: tv.video, correction: tv.correction, videoSize: tv.videoSize)
                    .opacity(isTunedToChannel && tv.phase == .playing ? 1 : 0)

                if !isTunedToChannel {
                    previewTuningOverlay(channel: ch, caption: ch?.isWatchable == false ? "COMING SOON" : "TUNING…")
                } else {
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
            }
            .frame(width: 624, height: 408)
            .clipped()
            .overlay(
                Rectangle()
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: 4)
                    .allowsHitTesting(false)
            )

            // Control bar on the bottom of the frame: ▼  CH 401  ▲ ........ SPELUNKR.TV
            HStack(spacing: 14) {
                Button {
                    stepChannel(by: -1)
                } label: {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 36, height: 28)
                }
                .buttonStyle(SpelunkrActionButtonStyle(
                    background: AnyShapeStyle(theme.raisedSurface),
                    restingBorder: theme.controlBorder,
                    horizontalPadding: 8,
                    verticalPadding: 4
                ))
                .focused($focus, equals: .channelDown)
                .onMoveCommand(perform: enterGrid)

                Text(ch.map { "CH \($0.dialText)" } ?? "CH --")
                    .font(theme.dialNumber(40))
                    .foregroundStyle(theme.accent)
                    .wsShadow()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 130)

                Button {
                    stepChannel(by: 1)
                } label: {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 36, height: 28)
                }
                .buttonStyle(SpelunkrActionButtonStyle(
                    background: AnyShapeStyle(theme.raisedSurface),
                    restingBorder: theme.controlBorder,
                    horizontalPadding: 8,
                    verticalPadding: 4
                ))
                .focused($focus, equals: .channelUp)
                .onMoveCommand(perform: enterGrid)

                Spacer(minLength: 0)

                Text("SPELUNKR.TV")
                    .font(theme.label(23))
                    .foregroundStyle(theme.accent)
                    .wsShadow()
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(width: 624, height: 56)
            .background(theme.raisedSurface.opacity(0.9), ignoresSafeAreaEdges: [])
        }
        .frame(width: 624, height: 464)
        .padding(8)
        .background(theme.panelFill, ignoresSafeAreaEdges: [])
        .clipShape(RoundedRectangle(cornerRadius: max(0, theme.panelCornerRadius - theme.panelInnerBorderWidth)))
        .overlay {
            RoundedRectangle(cornerRadius: max(0, theme.panelCornerRadius - theme.panelInnerBorderWidth))
                .strokeBorder(theme.panelBorder, lineWidth: borderWidth)
        }
        .overlay {
            Rectangle().strokeBorder(theme.panelInnerBorder, lineWidth: theme.panelInnerBorderWidth)
                .padding(borderWidth)
        }
        .frame(width: 640, height: 480)
    }

    private func previewTuningOverlay(channel: ChannelInfo?, caption: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [theme.baseSurface, theme.brandSurface.opacity(0.95), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 12) {
                if let rows = channel?.logomark?.rows, !rows.isEmpty {
                    LogomarkView(rows: rows, primaryColor: channel?.color, size: 96)
                }
                if let channel {
                    Text("CH \(channel.dialText) - \(channel.name)")
                        .font(theme.channelName(30))
                        .foregroundStyle(theme.accent)
                        .wsShadow()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(caption)
                    .font(theme.label(24))
                    .foregroundStyle(theme.secondaryAccent)
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

        return SpelunkrPanel {
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

                    // Height budget (inner 452 = 480 - 2 x 14 padding): header 52, description 56,
                    // divider 2, now playing 28 + 48 + 66, progress 30, divider 2, bottom bar 92,
                    // plus 7 gaps of 8 = 436.
                    VStack(alignment: .leading, spacing: 8) {
                        // Channel identity & LIVE/viewers row
                        HStack(spacing: 14) {
                            if let rows = ch.logomark?.rows, !rows.isEmpty {
                                LogomarkView(rows: rows, primaryColor: ch.color, size: 48)
                            } else {
                                Text(ch.emoji ?? "📺").font(.system(size: 38))
                                    .frame(width: 48, height: 48)
                            }

                            Text(ch.name)
                                .font(theme.channelName(34))
                                .foregroundStyle(theme.accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .wsShadow()

                            if let family = ch.family, !family.isEmpty {
                                FamilyBadge(family: family)
                            }

                            Text("CH \(ch.dialText)")
                                .font(theme.dialNumber(34))
                                .foregroundStyle(theme.softText)
                                .lineLimit(1)
                                .fixedSize()

                            Spacer(minLength: 8)

                            LiveBadge()
                            if viewers > 0 {
                                ViewerBadge(count: viewers, suffix: "WATCHING", fontSize: 23, color: theme.softText)
                            }
                        }
                        .frame(height: 52)

                        Text(ch.description ?? "")
                            .font(theme.body(23))
                            .foregroundStyle(theme.mutedText)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .topLeading)

                        panelDivider

                        // NOW PLAYING / INSPECTED
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inspectedBlock.map { "SCHEDULED - \(Theme.formatTime12($0.startMs))" } ?? "NOW PLAYING")
                                .font(theme.heading(28))
                                .foregroundStyle(theme.accent)

                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(program.title)
                                    .font(theme.heading(44))
                                    .foregroundStyle(theme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .wsShadow()

                                if let displayYear = program.year, !displayYear.isEmpty {
                                    Text(displayYear)
                                        .font(theme.label(26))
                                        .foregroundStyle(theme.secondaryAccent)
                                        .fixedSize()
                                }
                            }

                            Group {
                                if let blurb, !blurb.isEmpty {
                                    Text(blurb)
                                        .font(theme.body(26))
                                        .foregroundStyle(theme.softText)
                                } else if let inspected = inspectedBlock, inspected.isMarathon {
                                    Text("\(inspected.showCount) shows - \(inspected.spanText)")
                                        .font(theme.body(26))
                                        .foregroundStyle(theme.secondaryAccent)
                                } else {
                                    Text("")
                                }
                            }
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .topLeading)
                        }

                        // Progress bar (elapsed at the left end, remaining at the right end)
                        SpelunkrProgressBar(
                            progress: progress,
                            elapsedText: formatDuration(elapsedS),
                            remainingText: formatDuration(remainingS)
                        )
                        // Hidden (but spaced) while a future program is inspected.
                        .opacity(inspectedBlock == nil ? 1 : 0)
                        .frame(height: 30)

                        panelDivider

                        // Upcoming programs and guide actions.
                        HStack(alignment: .bottom, spacing: 20) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("UP NEXT")
                                    .font(theme.heading(28))
                                    .foregroundStyle(theme.accent)

                                ForEach(Array(upcoming), id: \.startMs) { next in
                                    HStack(spacing: 16) {
                                        Text(Theme.formatTime12(next.startMs))
                                            .font(theme.time(24))
                                            .foregroundStyle(theme.accent)
                                            .frame(width: 150, alignment: .leading)
                                        Text(next.title)
                                            .font(theme.body(25))
                                            .foregroundStyle(theme.primaryText)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .frame(height: 30)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)

                            guideActions(for: ch)
                        }
                    }
                    .padding(14)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                Text("Select a channel")
                    .font(theme.body(29))
                    .foregroundStyle(theme.softText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func guideActions(for channel: ChannelInfo) -> some View {
        HStack(spacing: 12) {
            Button {
                watch(channel)
            } label: {
                Text("WATCH")
                    .font(theme.button(26))
                    .foregroundStyle(theme.primaryText)
                    .wsShadow()
            }
            .buttonStyle(SpelunkrActionButtonStyle(
                background: AnyShapeStyle(theme.primaryActionFill),
                restingBorder: theme.accent,
                horizontalPadding: 24,
                verticalPadding: 10
            ))
            .disabled(!channel.isWatchable)
            .focused($focus, equals: .watch)
            .onMoveCommand(perform: enterGrid)

            Button {
                present(.channelSchedule(channel), returningTo: .viewChannel)
            } label: {
                Text("VIEW CHANNEL")
                    .font(theme.button(26))
                    .foregroundStyle(theme.primaryText)
                    .wsShadow()
            }
            .buttonStyle(SpelunkrActionButtonStyle(
                background: AnyShapeStyle(theme.secondaryActionFill),
                restingBorder: theme.controlBorder,
                horizontalPadding: 20,
                verticalPadding: 10
            ))
            .focused($focus, equals: .viewChannel)
            .onMoveCommand(perform: enterGrid)

            Button {
                present(.themePicker, returningTo: .themeMode)
            } label: {
                Text("Theme Mode")
                    .font(theme.button(26))
                    .foregroundStyle(theme.primaryText)
                    .wsShadow()
            }
            .buttonStyle(SpelunkrActionButtonStyle(
                background: AnyShapeStyle(theme.raisedSurface),
                restingBorder: theme.controlBorder,
                horizontalPadding: 20,
                verticalPadding: 10
            ))
            .focused($focus, equals: .themeMode)
            .onMoveCommand(perform: enterGrid)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func present(_ destination: Presentation, returningTo control: GuideFocus) {
        focusAfterDismissal = control
        presentation = destination
    }

    private func restoreGuideFocus() {
        guard let control = focusAfterDismissal else { return }
        focusAfterDismissal = nil
        focus = control
    }

    /// Thin rule between info panel sections.
    private var panelDivider: some View {
        Rectangle()
            .fill(theme.panelBorder.opacity(0.9))
            .frame(height: max(1, theme.panelInnerBorderWidth))
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

    /// Down from the top panel goes to the previewed channel's row, on the cell airing now.
    private func enterGrid(_ direction: MoveCommandDirection) {
        guard direction == .down, let ch = activeChannel, ch.isWatchable else { return }
        focusIntent = GuideGrid.FocusIntent(channelID: ch.id, atMs: Date.nowMs)
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

/// One program row of the VIEW CHANNEL schedule, with a focus highlight.
private struct ScheduleRowFrame<Content: View>: View {
    @Environment(\.appTheme) private var theme
    let airing: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        content()
            .padding(16)
            .background(fill, in: RoundedRectangle(cornerRadius: theme.cellCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: theme.cellCornerRadius)
                    .strokeBorder(
                        isFocused ? theme.focusBorder : (airing ? theme.selectedBorder : theme.panelBorder),
                        lineWidth: isFocused ? 4 : (airing ? 2 : 1)
                    )
            }
    }

    private var fill: AnyShapeStyle {
        if isFocused { return AnyShapeStyle(theme.focusedFill) }
        if airing { return theme.selectedRowFill }
        return AnyShapeStyle(theme.raisedSurface.opacity(0.85))
    }
}

private struct ChannelScheduleSheet: View {
    @Environment(\.appTheme) private var theme
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
                    LogomarkView(rows: rows, primaryColor: channel.color, size: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text("CH \(channel.dialText)")
                            .font(theme.dialNumber(44))
                            .foregroundStyle(theme.accent)
                        Text(channel.name)
                            .font(theme.channelName(36))
                            .foregroundStyle(theme.primaryText)
                        if let fam = channel.family { FamilyBadge(family: fam) }
                    }
                    if let desc = channel.description {
                        Text(desc)
                            .font(theme.body(23))
                            .foregroundStyle(theme.mutedText)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button {
                    onWatch()
                } label: {
                    Text("WATCH LIVE")
                        .font(theme.button(26))
                        .foregroundStyle(theme.primaryText)
                        .wsShadow()
                }
                .buttonStyle(SpelunkrActionButtonStyle(
                    background: AnyShapeStyle(theme.primaryActionFill),
                    restingBorder: theme.accent,
                    horizontalPadding: 28,
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

                        // Focusable so the remote can scroll through the day's schedule.
                        ScheduleRowFrame(airing: airing) {
                            HStack(alignment: .top, spacing: 20) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(Theme.formatTime12(program.startMs))
                                        .font(theme.time(26))
                                        .foregroundStyle(theme.accent)
                                    Text(formatDuration(program.durationS))
                                        .font(theme.label(23))
                                        .foregroundStyle(theme.mutedText)
                                }
                                .frame(width: 190, alignment: .leading)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 10) {
                                        if airing { LiveBadge() }
                                        Text(program.title)
                                            .font(theme.heading(32))
                                            .foregroundStyle(theme.primaryText)
                                        if let year = program.year {
                                            Text(year)
                                                .font(theme.label(24))
                                                .foregroundStyle(theme.secondaryAccent)
                                        }
                                    }
                                    if let blurb, !blurb.isEmpty {
                                        Text(blurb)
                                            .font(theme.body(24))
                                            .foregroundStyle(theme.softText)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .focusable()
                    }
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .background(theme.screenBackground.ignoresSafeArea())
        .onExitCommand { onClose() }
        .task(id: DetailsRequest(channel)) {
            await store.ensureDetails(for: channel)
            let now = Date.nowMs
            programs = await store.programs(for: channel.id, fromMs: now, toMs: now + 24 * 3600 * 1000)
        }
    }
}
