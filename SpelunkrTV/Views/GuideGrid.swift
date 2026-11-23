import SwiftUI

/// Everything on the guide home screen that can hold focus.
enum GuideFocus: Hashable {
    case channelDown
    case channelUp
    case watch
    case viewChannel
    case themeMode
    case browseChannel(String)
    case browseUpcoming(String, Double)
    case browseSchedule(String, String)
    case fullGuide
    case backToBrowse
    case cell(GuideGrid.GridCellID)
}

/// Cable time grid.
/// All rows share the same time window (`windowStartMs`), computed lazily per visible row.
///
/// Program cells are laid out at their time positions so tvOS can use their actual frames
/// for touch and directional focus. Explicit focus requests handle moves across time windows.
struct GuideGrid: View {
    @Environment(\.appTheme) private var theme
    private var windowDurationMs: Double { (theme.usesCableLayout ? 2 : 3) * 3600 * 1000 }
    static let stepMs: Double = 30 * 60 * 1000
    static let channelColumnWidth: CGFloat = 430
    /// Row height 80 + 2 spacing: five rows (412 pt with padding) fit the 418 pt scroll area.
    static let rowHeight: CGFloat = 80
    static let headerHeight: CGFloat = 50

    @Environment(BroadcastStore.self) private var store
    @Binding var selectedChannel: ChannelInfo?
    @Binding var inspectedBlock: GuideBlock?
    @Binding var windowStartMs: Double
    /// A request to focus the cell airing at `atMs` on one channel's row. The row fulfils it
    /// once its blocks for the current window are loaded.
    @Binding var focusIntent: FocusIntent?
    var focus: FocusState<GuideFocus?>.Binding
    let onWatch: (ChannelInfo) -> Void

    /// The cell we have just asked the focus engine for; its landing is accepted without checks.
    @State private var pendingLanding: FocusLanding?
    @State private var focusRetry: Task<Void, Never>?

    struct GridCellID: Hashable {
        let channelID: String
        let blockID: String
    }

    struct FocusIntent: Equatable {
        let id = UUID()
        let channelID: String
        let atMs: Double
    }

    private struct FocusLanding: Equatable {
        let cell: GridCellID
        let intent: FocusIntent
    }

    static func currentHalfHourMs(from nowMs: Double = Date.nowMs) -> Double {
        floor(nowMs / stepMs) * stepMs
    }

    /// The window actually shown: it never starts before the current half hour.
    private func effectiveWindowStart(nowMs: Double) -> Double {
        max(windowStartMs, Self.currentHalfHourMs(from: nowMs))
    }

    private var focusedChannelID: String? {
        guard case .cell(let cell)? = focus.wrappedValue else { return nil }
        return cell.channelID
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let nowMs = context.date.timeIntervalSince1970 * 1000
            grid(startingAt: effectiveWindowStart(nowMs: nowMs), nowMs: nowMs)
        }
        .onDisappear {
            focusRetry?.cancel()
            focusRetry = nil
            pendingLanding = nil
        }
        .onChange(of: focus.wrappedValue) { old, new in
            TuneLog.debug("[focus] \(String(describing: old)) -> \(String(describing: new))")
            guard let new, focusIntent == nil else { return }
            if case .cell = new { return }
            // First-row Up is handled by handleMove. A modal can restore focus to any guide control.
            focusRetry?.cancel()
            pendingLanding = nil
            inspectedBlock = nil
        }
    }

    private func grid(startingAt windowStartMs: Double, nowMs: Double) -> some View {
        let windowEndMs = windowStartMs + windowDurationMs

        return VStack(spacing: 0) {
            timeHeader(windowStartMs: windowStartMs, windowEndMs: windowEndMs, nowMs: nowMs)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(store.channels.enumerated()), id: \.element.id) { index, channel in
                            GuideGridRow(
                                channel: channel,
                                isEven: index % 2 == 0,
                                isSelectedRow: selectedChannel?.id == channel.id,
                                windowStartMs: windowStartMs,
                                windowEndMs: windowEndMs,
                                nowMs: nowMs,
                                focus: focus,
                                focusIntent: $focusIntent,
                                onCellFocused: handleCellFocus,
                                onCellActivate: { ch, block in
                                    selectedChannel = ch
                                    if block.isAiring(atMs: Date.nowMs) {
                                        inspectedBlock = nil
                                        onWatch(ch)
                                    } else {
                                        inspectedBlock = block
                                    }
                                },
                                onMove: { ch, block, visible, direction in
                                    handleMove(channel: ch, block: block, visible: visible,
                                               direction: direction, windowStartMs: windowStartMs)
                                },
                                onRequestFocus: { requestFocus($0) }
                            )
                            .id(channel.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .clipped()
                .onChange(of: selectedChannel?.id) { _, selectedID in
                    guard focusIntent == nil, focusedChannelID == nil, let selectedID else { return }
                    proxy.scrollTo(selectedID, anchor: .center)
                }
                .task(id: focusIntent) {
                    guard let intent = focusIntent else { return }
                    // Mount the destination row if the request targets another channel.
                    if focusedChannelID != intent.channelID {
                        proxy.scrollTo(intent.channelID, anchor: .center)
                    }
                    // A missing schedule should not keep an explicit request active indefinitely.
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled, focusIntent == intent { focusIntent = nil }
                }
            }
        }
        .background(theme.baseSurface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: theme.panelCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelCornerRadius)
                .stroke(theme.panelBorder, lineWidth: max(1, theme.panelInnerBorderWidth))
        }
    }

    // MARK: - Focus handling

    private func handleCellFocus(channel: ChannelInfo, block: GuideBlock) {
        let id = GridCellID(channelID: channel.id, blockID: block.id)
        if let intent = focusIntent {
            guard pendingLanding == FocusLanding(cell: id, intent: intent) else { return }
            focusRetry?.cancel()
            pendingLanding = nil
            focusIntent = nil
        }
        TuneLog.debug("[focus] landed \(channel.id) \(block.id)")
        if selectedChannel?.id != channel.id { selectedChannel = channel }
        inspectedBlock = block.isAiring(atMs: Date.nowMs) ? nil : block
    }

    /// Within the loaded grid, tvOS chooses the next target. Handle only edges here.
    private func handleMove(channel: ChannelInfo, block: GuideBlock, visible: [GuideBlock],
                            direction: MoveCommandDirection, windowStartMs: Double) {
        let nowMs = Date.nowMs
        TuneLog.debug("[focus] move \(direction) on \(channel.id) \(block.id) intent=\(focusIntent != nil)")
        switch direction {
        case .right:
            // Focus would leave the window: shift it by as little as shows the next program, and
            // move focus there, so one press is one move.
            guard visible.last?.id == block.id else { return }
            let next = block.endMs
            let needed = ceil((next - (windowDurationMs - Self.stepMs) - windowStartMs) / Self.stepMs)
            let steps = max(1, needed)
            setWindowStart(windowStartMs + steps * Self.stepMs)
            focusIntent = FocusIntent(channelID: channel.id, atMs: next)
        case .left:
            guard visible.first?.id == block.id else { return }
            let floorMs = Self.currentHalfHourMs(from: nowMs)
            guard windowStartMs > floorMs else { return }
            // Show the end of the previous program (this cell's start) with at least a step of room.
            let wanted = floor((block.startMs - Self.stepMs) / Self.stepMs) * Self.stepMs
            let earlier = max(floorMs, min(windowStartMs - Self.stepMs, wanted))
            setWindowStart(earlier)
            focusIntent = FocusIntent(channelID: channel.id, atMs: block.startMs - 1)
        case .up:
            guard store.watchableChannels.first?.id == channel.id else { return }
            focusIntent = nil
            focus.wrappedValue = .watch
        default:
            break
        }
    }

    private func setWindowStart(_ ms: Double) {
        if ms != windowStartMs { windowStartMs = ms }
    }

    /// The cell of a row that contains `ms` (else the closest one that started before it).
    static func cell(in blocks: [GuideBlock], at ms: Double) -> GuideBlock? {
        blocks.first { $0.startMs <= ms && ms < $0.endMs }
            ?? blocks.last { $0.startMs <= ms }
            ?? blocks.first
    }

    /// Moves focus to a cell on purpose. A cell that was only just built may not take focus on the
    /// first try, so it is repeated until the focus engine accepts it (or something else moves focus).
    private func requestFocus(_ id: GridCellID) {
        guard let intent = focusIntent else { return }
        let landing = FocusLanding(cell: id, intent: intent)
        guard pendingLanding != landing else { return }
        TuneLog.debug("[focus] request \(id.channelID) \(id.blockID)")
        pendingLanding = landing
        focusRetry?.cancel()
        focusRetry = Task { @MainActor in
            for _ in 0..<10 {
                await Task.yield()
                guard !Task.isCancelled, pendingLanding == landing, focusIntent == landing.intent else { break }
                if focus.wrappedValue != .cell(id) { focus.wrappedValue = .cell(id) }
                try? await Task.sleep(for: .milliseconds(120))
            }
            if !Task.isCancelled, pendingLanding == landing {
                pendingLanding = nil
                if focusIntent == landing.intent { focusIntent = nil }
            }
        }
    }

    // MARK: - Time Header

    private func timeHeader(windowStartMs: Double, windowEndMs: Double, nowMs: Double) -> some View {
        let hours = theme.usesCableLayout
            ? (0..<4).map { windowStartMs + Double($0) * Self.stepMs }
            : hourlyTicks(from: windowStartMs, to: windowEndMs)
        let total = store.presence.totalViewers

        return HStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(theme.usesCableLayout ? "ON NOW" : "CHANNEL")
                    .font(theme.label(24))
                    .foregroundStyle(theme.accent)
                    .wsShadow()
                Spacer()
                if total > 0 {
                    ViewerBadge(count: total, fontSize: 23, color: theme.secondaryAccent)
                        .wsShadow()
                }
            }
            .padding(.horizontal, 16)
            .frame(width: Self.channelColumnWidth, height: Self.headerHeight)
            .background(theme.gridHeaderFill, ignoresSafeAreaEdges: [])
            .overlay(alignment: .trailing) {
                Rectangle().fill(theme.panelBorder).frame(width: max(1, theme.panelInnerBorderWidth))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    theme.gridHeaderFill

                    ForEach(hours, id: \.self) { tickMs in
                        let pct = (tickMs - windowStartMs) / windowDurationMs
                        let x = max(10, min(geo.size.width - 190, geo.size.width * pct))
                        Text(Theme.formatTime12(tickMs))
                            .font(theme.time(27))
                            .foregroundStyle(theme.primaryText)
                            .wsShadow()
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: x)
                    }

                    // "Now" marker on the bottom edge of the time header.
                    if nowMs >= windowStartMs && nowMs <= windowEndMs {
                        let nowX = geo.size.width * ((nowMs - windowStartMs) / windowDurationMs)
                        Rectangle()
                            .fill(theme.liveIndicator)
                            .frame(width: 4, height: 12)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .offset(x: nowX)
                    }

                    if windowStartMs > Self.currentHalfHourMs() {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "arrowtriangle.left.fill").font(.system(size: 14))
                                Text("EARLIER / LATER")
                                    .font(theme.label(21))
                                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 14))
                            }
                            .foregroundStyle(theme.secondaryAccent.opacity(0.9))
                            .padding(.trailing, 14)
                        }
                    }
                }
            }
            .frame(height: Self.headerHeight)
            .clipped()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.panelBorder).frame(height: max(1, theme.panelInnerBorderWidth))
        }
    }

    private func hourlyTicks(from startMs: Double, to endMs: Double) -> [Double] {
        let hourMs: Double = 3600 * 1000
        var first = ceil(startMs / hourMs) * hourMs
        if first - startMs > 1800 * 1000 {
            first = startMs
        }
        var ticks: [Double] = []
        var t = first
        while t < endMs - 600_000 {
            ticks.append(t)
            t += hourMs
        }
        if ticks.isEmpty { ticks.append(startMs) }
        return ticks
    }
}

// MARK: - Single Channel Row

private struct GuideGridRow: View {
    @Environment(\.appTheme) private var theme
    @Environment(BroadcastStore.self) private var store
    let channel: ChannelInfo
    let isEven: Bool
    let isSelectedRow: Bool
    let windowStartMs: Double
    let windowEndMs: Double
    let nowMs: Double
    var focus: FocusState<GuideFocus?>.Binding
    @Binding var focusIntent: GuideGrid.FocusIntent?
    let onCellFocused: (ChannelInfo, GuideBlock) -> Void
    let onCellActivate: (ChannelInfo, GuideBlock) -> Void
    let onMove: (ChannelInfo, GuideBlock, [GuideBlock], MoveCommandDirection) -> Void
    let onRequestFocus: (GuideGrid.GridCellID) -> Void

    @State private var blocks: [GuideBlock] = []
    /// Window start the current `blocks` were loaded for (blocks are stale until it matches).
    @State private var loadedWindowStartMs: Double = -1

    /// Blocks that actually show in the window (a block that only touches an edge has no width).
    private var visibleBlocks: [GuideBlock] {
        blocks.filter { $0.endMs > windowStartMs && $0.startMs < windowEndMs }
    }

    private var taskKey: String {
        "\(channel.id)|\(Int64(windowStartMs))|\(store.scheduleRevision)"
    }

    /// Give a clipped live cell room for a label. Leave at least half of its neighbor visible.
    /// This only adjusts drawing bounds; the program keeps its original schedule times.
    private func leadingLiveEnd(in visible: [GuideBlock], rowWidth: CGFloat) -> Double? {
        guard rowWidth > 0, let first = visible.first,
              first.startMs < windowStartMs, first.isAiring(atMs: nowMs) else { return nil }
        let labelEnd = windowStartMs + min(1, 120 / rowWidth) * (windowEndMs - windowStartMs)
        guard first.endMs < labelEnd else { return nil }
        let next = visible.dropFirst().first
        let limit = next.map { ($0.startMs + min($0.endMs, windowEndMs)) / 2 } ?? windowEndMs
        return max(first.endMs, min(labelEnd, limit))
    }

    var body: some View {
        let rowBg = isEven ? theme.baseSurface.opacity(0.92) : theme.alternateRowFill.opacity(0.38)
        let viewers = store.presence.count(for: channel.id)

        HStack(spacing: 0) {
            // Pinned channel column
            HStack(spacing: 10) {
                Text(channel.dialText)
                    .font(theme.dialNumber(theme.usesCableLayout ? 36 : 52))
                    .foregroundStyle(theme.usesCableLayout ? theme.primaryText : theme.accent)
                    .wsShadow()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 88, alignment: .trailing)

                if let rows = channel.logomark?.rows, !rows.isEmpty {
                    LogomarkView(rows: rows, primaryColor: channel.color, size: 48)
                } else {
                    Text(channel.emoji ?? "📺")
                        .font(.system(size: 34))
                        .frame(width: 48, height: 48)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(theme.usesCableLayout ? channel.name.uppercased() : channel.name)
                        .font(theme.channelName(24))
                        .foregroundStyle(theme.usesCableLayout ? (Color(hex: channel.color) ?? theme.secondaryAccent) : theme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .wsShadow()
                    if channel.comingSoon == true {
                        Text("COMING SOON")
                            .font(theme.label(23))
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                    } else if viewers > 0, !theme.usesCableLayout {
                        ViewerBadge(count: viewers, fontSize: 23, color: isSelectedRow ? theme.secondaryAccent : theme.mutedText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: GuideGrid.channelColumnWidth, height: GuideGrid.rowHeight)
            .background(isSelectedRow ? theme.selectedRowFill : AnyShapeStyle(theme.raisedSurface.opacity(0.95)), ignoresSafeAreaEdges: [])
            .clipped()
            .overlay(alignment: .trailing) {
                Rectangle().fill(theme.panelBorder).frame(width: max(1, theme.panelInnerBorderWidth))
            }

            // Proportional program cells
            GeometryReader { geo in
                let totalMs = max(1, windowEndMs - windowStartMs)
                let visible = visibleBlocks
                let leadingEnd = leadingLiveEnd(in: visible, rowWidth: geo.size.width)
                let firstID = visible.first?.id
                let secondID = visible.dropFirst().first?.id

                ZStack(alignment: .leading) {
                    rowBg

                    if visible.isEmpty {
                        Text(channel.comingSoon == true ? "COMING SOON" : "Loading schedule…")
                            .font(theme.gridText(26))
                            .foregroundStyle(theme.mutedText.opacity(0.75))
                            .padding(.horizontal, 16)
                    } else {
                        ProgramCellLayout {
                            ForEach(visible) { block in
                                let start = block.id == secondID ? max(block.startMs, leadingEnd ?? block.startMs) : block.startMs
                                let end = block.id == firstID ? leadingEnd ?? block.endMs : block.endMs
                                let clampedStart = max(start, windowStartMs)
                                let clampedEnd = min(end, windowEndMs)
                                let leftX = geo.size.width * ((clampedStart - windowStartMs) / totalMs)
                                let rawWidth = geo.size.width * (max(0, clampedEnd - clampedStart) / totalMs)
                                let width = max(0, rawWidth - min(2, rawWidth / 2))
                                let cellID = GuideGrid.GridCellID(channelID: channel.id, blockID: block.id)
                                let isCurrent = block.isAiring(atMs: nowMs)

                                Button {
                                    onCellActivate(channel, block)
                                } label: {
                                    GuideProgramCell(
                                        channelName: channel.name,
                                        block: block,
                                        isCurrent: isCurrent,
                                        isRowSelected: isSelectedRow,
                                        nowMs: nowMs
                                    )
                                    .frame(width: width, height: GuideGrid.rowHeight - 2)
                                    .clipped()
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(SpelunkrPlainFocusButtonStyle())
                                .accessibilityValue(isCurrent ? Text("Live") : Text(""))
                                .disabled(!channel.isWatchable)
                                .focused(focus, equals: .cell(cellID))
                                .onMoveCommand { direction in
                                    onMove(channel, block, visible, direction)
                                }
                                .layoutValue(
                                    key: ProgramCellFrame.self,
                                    value: CGRect(x: leftX, y: 0, width: width, height: GuideGrid.rowHeight - 2)
                                )
                            }
                        }
                    }

                    // Mark the current time in the row gutter, clear of both lines of cell text.
                    if nowMs >= windowStartMs && nowMs < windowEndMs {
                        let nowX = geo.size.width * ((nowMs - windowStartMs) / totalMs)
                        Rectangle()
                            .fill(theme.liveIndicator.opacity(0.65))
                            .frame(width: 2, height: 7)
                            .frame(height: GuideGrid.rowHeight, alignment: .bottom)
                            .offset(x: nowX)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: GuideGrid.rowHeight)
            .clipped()
        }
        .frame(height: GuideGrid.rowHeight)
        .clipped()
        .overlay(
            RoundedRectangle(cornerRadius: theme.usesCableLayout ? theme.cellCornerRadius : 0)
                .strokeBorder(isSelectedRow ? theme.selectedBorder : theme.gridLine, lineWidth: isSelectedRow ? 3 : 1)
        )
        .task(id: taskKey) {
            let updated = await store.blocks(for: channel.id, fromMs: windowStartMs, toMs: windowEndMs)
            guard !Task.isCancelled else { return }
            blocks = updated
            loadedWindowStartMs = windowStartMs
            fulfillIntent(blocks: updated, loadedFor: windowStartMs)
        }
        .onChange(of: focusIntent) { _, _ in
            fulfillIntent(blocks: blocks, loadedFor: loadedWindowStartMs)
        }
        .onChange(of: focus.wrappedValue) { _, new in
            guard case .cell(let id)? = new, id.channelID == channel.id,
                  let block = blocks.first(where: { $0.id == id.blockID }) else { return }
            onCellFocused(channel, block)
        }
    }

    /// Answers a focus request for this row once its blocks match the current window.
    private func fulfillIntent(blocks: [GuideBlock], loadedFor loadedStart: Double) {
        guard let intent = focusIntent, intent.channelID == channel.id else { return }
        TuneLog.debug("[focus] fulfil \(channel.id) loaded=\(loadedStart == windowStartMs) blocks=\(blocks.count)")
        guard channel.isWatchable else { focusIntent = nil; return }
        guard loadedStart == windowStartMs else { return }
        let visible = blocks.filter { $0.endMs > windowStartMs && $0.startMs < windowEndMs }
        guard let target = GuideGrid.cell(in: visible, at: intent.atMs) else { return }
        let targetID = GuideGrid.GridCellID(channelID: channel.id, blockID: target.id)
        onRequestFocus(targetID)
        if focus.wrappedValue == .cell(targetID) {
            // Native focus may already be at the destination before the row fulfils the intent.
            onCellFocused(channel, target)
        }
    }
}

private struct ProgramCellFrame: LayoutValueKey {
    static let defaultValue: CGRect = .zero
}

private struct ProgramCellLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let frame = subview[ProgramCellFrame.self]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

// MARK: - Program / Marathon Cell

private struct GuideProgramCell: View {
    @Environment(\.appTheme) private var theme
    let channelName: String
    let block: GuideBlock
    let isCurrent: Bool
    let isRowSelected: Bool
    let nowMs: Double
    @Environment(\.isFocused) private var isCellFocused

    var body: some View {
        let activeShow = block.activeShow(atMs: nowMs)
        let primaryTitle: String = {
            if block.isMarathon {
                if isCurrent, let show = activeShow {
                    return show.title
                }
                return block.marathonHeadline(channelName: channelName)
            }
            return block.title
        }()

        let subtitle: String = {
            if block.isMarathon {
                if isCurrent, activeShow != nil {
                    return block.marathonHeadline(channelName: channelName)
                }
                return "\(block.showCount) shows - \(block.spanText)"
            }
            return formatDuration(block.durationS)
        }()

        VStack(alignment: .leading, spacing: 0) {
            Text(primaryTitle)
                .font(theme.gridText(29))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .wsShadow()

            if !theme.usesCableLayout {
                Text(subtitle)
                    .font(theme.label(23))
                    .foregroundStyle(isCellFocused ? theme.softText : (block.isMarathon ? theme.secondaryAccent : theme.mutedText))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(cellBackground, in: RoundedRectangle(cornerRadius: theme.cellCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cellCornerRadius)
                .strokeBorder(isCellFocused ? theme.focusBorder : theme.panelBorder.opacity(0.65), lineWidth: isCellFocused ? 4 : 1)
        }
        .overlay(alignment: .leading) {
            if isCurrent, let marker = theme.liveProgramMarker {
                Capsule()
                    .fill(marker)
                    .frame(width: 3, height: 22)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var cellBackground: AnyShapeStyle {
        if isCellFocused {
            return AnyShapeStyle(theme.focusedFill)
        }
        if isCurrent {
            return AnyShapeStyle(theme.usesCableLayout ? theme.alternateRowFill : Color.white.opacity(isRowSelected ? 0.14 : 0.08))
        }
        return AnyShapeStyle(theme.raisedSurface.opacity(0.55))
    }
}
