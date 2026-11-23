import SwiftUI

/// The guide is removed while the player owns the screen.
struct GuidePlaybackOrigin {
    let channelID: String
    let target: GuideFocus?
    let fullGuide: Bool
    let windowStartMs: Double
    let browseChannelID: String?
}

/// Shared navigation, channel selection, and preview tuning for the timeline and browse layouts.
struct GuideHome: View {
    @Environment(\.appTheme) private var theme
    @Environment(BroadcastStore.self) private var store
    @Binding var selectedChannel: ChannelInfo?
    @Binding var playbackOrigin: GuidePlaybackOrigin?
    let onWatch: (ChannelInfo) -> Void

    @State private var inspectedBlock: GuideBlock?
    @State private var windowStartMs: Double = GuideGrid.currentHalfHourMs()
    @State private var presentation: Presentation?
    @State private var focusAfterDismissal: GuideFocus?
    @State private var showingFullGuide = false
    @State private var browseFocusRequest: BrowseFocusRequest?
    @State private var channelBeforeFullGuide: ChannelInfo?
    @State private var hasAppeared = false
    @State private var previewDebounceTask: Task<Void, Never>?
    @State private var focusIntent: GuideGrid.FocusIntent?
    @FocusState private var focus: GuideFocus?

    private enum Presentation: Identifiable {
        case channelSchedule(ChannelInfo)
        case themePicker
        case program(ChannelInfo, GuideEntry)

        var id: String {
            switch self {
            case .channelSchedule(let channel): return "schedule-\(channel.id)"
            case .themePicker: return "theme-picker"
            case .program(let channel, let entry): return "program-\(channel.id)-\(entry.startMs)"
            }
        }
    }

    private var activeChannel: ChannelInfo? {
        store.channels.first { $0.id == selectedChannel?.id && $0.isWatchable }
            ?? store.channels.first(where: \.isWatchable)
            ?? store.channels.first
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

            if theme.guideLayout == .timeline {
                timelineHeader
                timelineGrid
            } else {
                ZStack {
                    browseHome
                        .disabled(showingFullGuide)
                        .allowsHitTesting(!showingFullGuide)
                        .accessibilityHidden(showingFullGuide)
                        .opacity(showingFullGuide ? 0 : 1)
                    if showingFullGuide { fullGuide }
                }
            }
        }
        // tvOS title-safe margins (80 pt left/right, 60 pt top/bottom). Height at 1080:
        // 60 + 480 (top) + 12 + 468 (grid: 50 header + 418 rows) + 60 = 1080.
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .background(theme.screenBackground.ignoresSafeArea())
        .cableScanlines()
        .onPlayPauseCommand {
            if presentation == nil, focusAfterDismissal == nil { focusLiveProgram(preferLiveProgram: true) }
        }
        .onAppear {
            // A cover can hide and reveal this guide without replacing its state.
            guard !hasAppeared else { return }
            hasAppeared = true
            if let channel = activeChannel, channel.isWatchable {
                selectedChannel = channel
                schedulePreviewTune(for: channel, immediate: store.tv.channel == nil)
            } else {
                selectedChannel = nil
            }
            if let origin = playbackOrigin {
                playbackOrigin = nil
                restorePlayerOrigin(origin)
            } else {
                focusLiveProgram()
            }
        }
        .onChange(of: store.watchableChannels.map(\.id)) { _, ids in
            switch presentation {
            case .channelSchedule(let channel), .program(let channel, _):
                if !ids.contains(channel.id) { presentation = nil }
            default:
                break
            }
            guard !ids.contains(selectedChannel?.id ?? "") else { return }
            selectedChannel = store.watchableChannels.first
            inspectedBlock = nil
            if ids.isEmpty {
                previewDebounceTask?.cancel()
                store.tv.stop()
                store.presence.track(channelID: nil)
                focus = showingFullGuide ? .backToBrowse : .themeMode
            } else {
                focusLiveProgram()
            }
        }
        .onChange(of: theme.guideLayout) { _, _ in
            showingFullGuide = false
            focusIntent = nil
            browseFocusRequest = nil
            if let channel = activeChannel {
                schedulePreviewTune(for: channel, immediate: true)
            }
        }
        .onChange(of: focus) { _, target in
            guard presentation == nil, let target else { return }
            let id: String
            switch target {
            case .browseChannel(let channelID), .browseUpcoming(let channelID, _), .browseSchedule(let channelID, _):
                id = channelID
            default:
                return
            }
            if selectedChannel?.id != id, let channel = store.channels.first(where: { $0.id == id }) {
                selectedChannel = channel
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
        .task(id: theme.guideLayout == .timeline ? activeChannel.map(DetailsRequest.init) : nil) {
            if theme.guideLayout == .timeline, let ch = activeChannel {
                await store.ensureDetails(for: ch)
            }
        }
        .fullScreenCover(item: $presentation, onDismiss: restoreGuideFocus) { presented in
            switch presented {
            case .channelSchedule(let channel):
                ChannelScheduleSheet(channel: store.channels.first { $0.id == channel.id } ?? channel) {
                    watch(channel)
                    focusAfterDismissal = nil
                    presentation = nil
                } onClose: {
                    presentation = nil
                }
            case .program(let channel, let entry):
                programDetails(channel, entry: entry)
            case .themePicker:
                ThemePicker {
                    presentation = nil
                }
            }
        }
    }

    private var timelineHeader: some View {
        Group {
            if theme.usesCableLayout {
                cableGuideHeader
            } else {
                HStack(alignment: .top, spacing: 20) {
                    previewPane.frame(width: 640, height: 480)
                    infoPanel.frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
                }
            }
        }
        .focusSection()
    }

    private var timelineGrid: some View {
        GuideGrid(
            selectedChannel: $selectedChannel,
            inspectedBlock: $inspectedBlock,
            windowStartMs: $windowStartMs,
            focusIntent: $focusIntent,
            focus: $focus,
            emptyGridFocus: showingFullGuide ? .backToBrowse : .themeMode,
            onWatch: watch
        )
        .frame(maxHeight: .infinity)
        .focusSection()
    }

    private var browseHome: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                Text(theme.name)
                    .font(theme.heading(38))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                browseButton("Full Guide", target: .fullGuide) {
                    browseFocusRequest = nil
                    channelBeforeFullGuide = activeChannel
                    showingFullGuide = true
                    requestGridFocus()
                }
                browseButton("Theme Mode", target: .themeMode) {
                    present(.themePicker, returningTo: .themeMode)
                }
            }
            .focusSection()
            ThemeBrowseView(
                channels: store.channels,
                selectedChannel: showingFullGuide ? (channelBeforeFullGuide ?? activeChannel) : activeChannel,
                focus: $focus,
                focusRequest: $browseFocusRequest, preview: { previewPicture }, onWatch: watch,
                onInspect: { channel, entry in
                    present(.program(channel, entry), returningTo: focus ?? .browseChannel(channel.id))
                }
            )
        }
    }

    private var fullGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Full Guide").font(theme.heading(46))
                    if let channel = activeChannel {
                        TimelineView(.everyMinute) { context in
                            let now = context.date.timeIntervalSince1970 * 1000
                            let live = store.guide[channel.id]?.first { $0.startMs <= now && now < $0.endMs }
                            let start = inspectedBlock?.startMs ?? live?.startMs
                            let end = inspectedBlock?.endMs ?? live?.endMs
                            VStack(alignment: .leading, spacing: 4) {
                                Text(inspectedBlock?.title ?? live?.title ?? channel.name)
                                    .font(theme.body(theme.guideLayout == .largePrint ? 42 : 32))
                                    .lineLimit(2, reservesSpace: true)
                                if let start, let end {
                                    Text("\(channel.name) · \(inspectedBlock == nil ? "Live · " : "")\(Theme.formatTime12(start)) – \(Theme.formatTime12(end))")
                                        .font(theme.time(theme.guideLayout == .largePrint ? 34 : 24))
                                        .lineLimit(1)
                                        .foregroundStyle(theme.mutedText)
                                }
                            }
                        }
                    }
                }
                Spacer()
                if let channel = activeChannel {
                    browseButton("Watch Live", target: .watch) { watch(channel) }
                        .disabled(!channel.isWatchable)
                        .onMoveCommand(perform: enterGrid)
                }
                browseButton("Back to Browse", target: .backToBrowse, action: closeFullGuide)
            }
            .foregroundStyle(theme.primaryText)
            .focusSection()
            timelineGrid
        }
        .onExitCommand(perform: closeFullGuide)
    }

    private func closeFullGuide() {
        showingFullGuide = false
        focusIntent = nil
        inspectedBlock = nil
        if let channel = store.watchableChannels.first(where: { $0.id == channelBeforeFullGuide?.id }) { selectedChannel = channel }
        channelBeforeFullGuide = nil
        browseFocusRequest = BrowseFocusRequest(target: .fullGuide)
    }

    private func browseButton(_ title: String, target: GuideFocus, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.button(theme.guideLayout == .largePrint ? 36 : 28))
                .foregroundStyle(theme.primaryText)
                .fixedSize()
        }
        .buttonStyle(SpelunkrActionButtonStyle(background: AnyShapeStyle(theme.raisedSurface)))
        .focused($focus, equals: target)
    }

    private func programDetails(_ channel: ChannelInfo, entry: GuideEntry) -> some View {
        let _ = store.detailsRevision
        return VStack(alignment: .leading, spacing: 24) {
            Text("CH \(channel.dialText) · \(channel.name)").font(theme.label(32))
            Text(entry.title).font(theme.heading(56))
            HStack(spacing: 18) {
                Text("\(Theme.formatTime12(entry.startMs)) – \(Theme.formatTime12(entry.endMs))")
                if let year = entry.year, !year.isEmpty { Text(year) }
            }
            .font(theme.time(34))
            if let blurb = store.detail(channelID: channel.id, version: entry.version, videoIndex: entry.videoIndex)?.description {
                Text(blurb).font(theme.body(32)).lineLimit(6)
            }
            GuideBackButton { presentation = nil }
        }
        .foregroundStyle(theme.primaryText)
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(theme.screenBackground.ignoresSafeArea())
        .onExitCommand { presentation = nil }
        .task(id: DetailsRequest(channel)) { await store.ensureDetails(for: channel) }
    }

    // MARK: - Top Left: Live Preview

    private var previewPane: some View {
        let ch = activeChannel
        // Keep the same video and control area across themes.
        let borderWidth = theme.panelBorderWidth + theme.panelInnerBorderWidth
        return VStack(spacing: 0) {
            previewPicture
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
                .accessibilityLabel("Previous channel")
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
                .accessibilityLabel("Next channel")
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

    private var cableGuideHeader: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.timeIntervalSince1970 * 1000
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 32) {
                    Text("SPELUNKR").font(theme.heading(46)).foregroundStyle(theme.accent)
                    Text("PROGRAM GUIDE").font(theme.label(30)).foregroundStyle(theme.primaryText)
                    Spacer()
                    Text(context.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(theme.time(30))
                        .foregroundStyle(theme.softText)
                }
                HStack(alignment: .top, spacing: 52) {
                    if let channel = activeChannel {
                        cableProgramDetails(channel, now: now)
                    }
                    Spacer(minLength: 0)
                    previewPicture
                        .frame(width: 576, height: 324)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cellCornerRadius))
                }
            }
        }
    }

    private func cableProgramDetails(_ channel: ChannelInfo, now: Double) -> some View {
        let _ = store.detailsRevision
        let airing = store.guide[channel.id]?.first { $0.startMs <= now && now < $0.endMs }
        let tuned = store.tv.channel?.id == channel.id ? store.tv.onAir : nil
        let title = inspectedBlock?.title ?? airing?.title ?? tuned?.displayTitle ?? "Tuning…"
        let start = inspectedBlock?.startMs ?? airing?.startMs ?? tuned?.startMs
        let end = inspectedBlock?.endMs ?? airing?.endMs ?? tuned?.endMs
        let description = store.detail(
            channelID: channel.id,
            version: inspectedBlock == nil ? (airing?.version ?? tuned?.version) : inspectedBlock?.version,
            videoIndex: inspectedBlock == nil ? (airing?.videoIndex ?? tuned?.videoIndex) : inspectedBlock?.videoIndex
        )?.description ?? channel.description

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                if let rows = channel.logomark?.rows, !rows.isEmpty {
                    LogomarkView(rows: rows, primaryColor: channel.color, size: 82)
                } else if let emoji = channel.emoji {
                    Text(emoji).font(.system(size: 58)).frame(width: 82, height: 82)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("CH \(channel.dialText)").font(theme.time(26)).foregroundStyle(theme.mutedText)
                    Text(channel.name.uppercased()).font(theme.channelName(40)).foregroundStyle(theme.secondaryAccent)
                        .lineLimit(1)
                }
            }
            Text(title).font(theme.heading(38)).foregroundStyle(theme.primaryText).lineLimit(inspectedBlock == nil ? 1 : 2)
            if let start, let end {
                Text("\(Theme.formatTime12(start)) – \(Theme.formatTime12(end))")
                    .font(theme.time(26)).foregroundStyle(theme.mutedText)
            }
            if let description {
                Text(description).font(theme.body(25)).foregroundStyle(theme.softText).lineLimit(inspectedBlock == nil ? 2 : 1)
            }
            Spacer(minLength: 0)
            guideActions(for: channel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 324)
    }

    private var previewPicture: some View {
        let ch = activeChannel
        let tv = store.tv
        // The preview is only valid for the highlighted channel; between a row change and the retune
        // it must not show the previous channel's last frame.
        let isTunedToChannel = ch != nil && tv.channel?.id == ch?.id

        return ZStack {
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

                        if inspectedBlock == nil {
                            Text(ch.description ?? "")
                                .font(theme.body(23))
                                .foregroundStyle(theme.mutedText)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .topLeading)
                        }

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
                                    .lineLimit(inspectedBlock == nil ? 1 : 2)
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
                Text(theme.usesCableLayout ? "SETTINGS" : "Theme Mode")
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
        switch control {
        case .browseChannel, .browseSchedule, .browseUpcoming:
            browseFocusRequest = BrowseFocusRequest(target: control)
        default:
            focus = control
        }
    }

    /// Thin rule between info panel sections.
    private var panelDivider: some View {
        Rectangle()
            .fill(theme.panelBorder.opacity(0.9))
            .frame(height: max(1, theme.panelInnerBorderWidth))
    }

    // MARK: - Preview Tuning & Channel Stepping

    private func restorePlayerOrigin(_ origin: GuidePlaybackOrigin) {
        showingFullGuide = origin.fullGuide && theme.guideLayout != .timeline
        channelBeforeFullGuide = store.watchableChannels.first { $0.id == origin.browseChannelID }
        guard let current = activeChannel, current.isWatchable else {
            focus = showingFullGuide ? .backToBrowse : .themeMode
            return
        }
        guard current.id == origin.channelID, let target = origin.target else {
            focusLiveProgram(preferLiveProgram: true)
            return
        }
        windowStartMs = max(origin.windowStartMs, GuideGrid.currentHalfHourMs())
        switch target {
        case .browseSchedule, .browseUpcoming, .browseChannel:
            browseFocusRequest = BrowseFocusRequest(target: target)
        case .cell:
            requestGridFocus()
        default:
            Task { @MainActor in
                await Task.yield()
                focus = target
            }
        }
    }

    private func watch(_ channel: ChannelInfo) {
        guard let channel = store.watchableChannels.first(where: { $0.id == channel.id }) else { return }
        previewDebounceTask?.cancel()
        playbackOrigin = GuidePlaybackOrigin(
            channelID: channel.id,
            target: focusAfterDismissal ?? focus,
            fullGuide: showingFullGuide,
            windowStartMs: windowStartMs,
            browseChannelID: channelBeforeFullGuide?.id
        )
        onWatch(channel)
    }

    private func schedulePreviewTune(for channel: ChannelInfo, immediate: Bool) {
        previewDebounceTask?.cancel()
        switch theme.guideLayout {
        case .timeline, .daylight, .cinema, .channelWall:
            break
        case .scheduleDesk, .largePrint, .spotlight:
            if store.tv.channel != nil {
                store.tv.stop()
                store.presence.track(channelID: nil)
            }
            return
        }
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
        if direction == .down { focusLiveProgram() }
    }

    private func focusLiveProgram(preferLiveProgram: Bool = false) {
        if theme.guideLayout == .timeline || showingFullGuide {
            requestGridFocus()
        } else if let channel = activeChannel {
            browseFocusRequest = BrowseFocusRequest(
                target: .browseChannel(channel.id),
                preferLiveProgram: preferLiveProgram
            )
        }
    }

    private func requestGridFocus() {
        guard let channel = activeChannel, channel.isWatchable else {
            focus = showingFullGuide ? .backToBrowse : .themeMode
            return
        }
        let nowMs = Date.nowMs
        windowStartMs = GuideGrid.currentHalfHourMs(from: nowMs)
        inspectedBlock = nil
        focusIntent = GuideGrid.FocusIntent(channelID: channel.id, atMs: nowMs, requiresLive: true)
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

struct GuideBackButton: View {
    @Environment(\.appTheme) private var theme
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            Label("Back to Guide", systemImage: "chevron.left")
                .font(theme.button(24))
                .foregroundStyle(theme.primaryText)
                .fixedSize()
        }
        .buttonStyle(SpelunkrActionButtonStyle(background: AnyShapeStyle(theme.raisedSurface)))
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

    @State private var programs: [GuideProgram]?

    private struct ListingsRequest: Equatable {
        let channelID: String
        let revision: Int
        let halfHour: Double
    }

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

                GuideBackButton(onBack: onClose)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date.timeIntervalSince1970 * 1000
                let request = ListingsRequest(channelID: channel.id, revision: store.scheduleRevision,
                                              halfHour: GuideGrid.currentHalfHourMs(from: now))
                Group {
                    if let programs {
                        let visible = programs.filter { $0.endMs > now && $0.startMs < now + 86_400_000 }
                        if visible.isEmpty {
                            Text("Schedule unavailable").font(theme.body(28)).foregroundStyle(theme.mutedText)
                        } else {
                            listings(visible, now: now)
                        }
                    } else {
                        ProgressView("Loading schedule…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .task(id: request) {
                    let updated = await store.programs(
                        for: request.channelID,
                        fromMs: request.halfHour,
                        toMs: request.halfHour + GuideGrid.stepMs + 86_400_000
                    )
                    guard !Task.isCancelled, request.revision == store.scheduleRevision else { return }
                    programs = updated
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .background(theme.screenBackground.ignoresSafeArea())
        .cableScanlines()
        .onExitCommand { onClose() }
        .task(id: DetailsRequest(channel)) {
            await store.ensureDetails(for: channel)
        }
    }

    private func listings(_ programs: [GuideProgram], now: Double) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(programs) { program in
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
}
