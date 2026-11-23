import SwiftUI

/// 3-hour WeatherStar 4000 cable time grid.
/// All 37 rows share the same 3-hour window (`windowStartMs`), computed lazily per visible row.
struct GuideGrid: View {
    static let windowDurationMs: Double = 3 * 3600 * 1000
    static let stepMs: Double = 30 * 60 * 1000
    static let channelColumnWidth: CGFloat = 350
    static let rowHeight: CGFloat = 78

    @Environment(BroadcastStore.self) private var store
    @Binding var selectedChannel: ChannelInfo?
    @Binding var inspectedBlock: GuideBlock?
    @Binding var windowStartMs: Double
    let onWatch: (ChannelInfo) -> Void

    @FocusState private var focusedCell: GridCellID?

    struct GridCellID: Hashable {
        let channelID: String
        let blockID: String
    }

    static func currentHalfHourMs(from nowMs: Double = Date.nowMs) -> Double {
        floor(nowMs / stepMs) * stepMs
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let nowMs = context.date.timeIntervalSince1970 * 1000
            grid(startingAt: max(windowStartMs, Self.currentHalfHourMs(from: nowMs)), nowMs: nowMs)
        }
    }

    private func grid(startingAt windowStartMs: Double, nowMs: Double) -> some View {
        let windowEndMs = windowStartMs + Self.windowDurationMs

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
                                focusedCell: $focusedCell,
                                onRowFocused: { ch, block in
                                    selectedChannel = ch
                                    if let block, !block.isAiring(atMs: Date.nowMs) {
                                        inspectedBlock = block
                                    } else {
                                        inspectedBlock = nil
                                    }
                                },
                                onCellActivate: { ch, block in
                                    selectedChannel = ch
                                    if block.isAiring(atMs: Date.nowMs) {
                                        inspectedBlock = nil
                                        onWatch(ch)
                                    } else {
                                        inspectedBlock = block
                                    }
                                },
                                onShiftWindow: { deltaSteps in
                                    shiftWindow(bySteps: deltaSteps)
                                }
                            )
                            .id(channel.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .clipped()
                .onChange(of: selectedChannel?.id) { _, newID in
                    if let newID {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Theme.deepNavy.opacity(0.95))
        .clipped()
        .overlay(Rectangle().stroke(Theme.ringOuter, lineWidth: 2))
    }

    // MARK: - Time Header

    private func timeHeader(windowStartMs: Double, windowEndMs: Double, nowMs: Double) -> some View {
        let hours = hourlyTicks(from: windowStartMs, to: windowEndMs)
        let total = store.presence.totalViewers

        return HStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("CHANNEL")
                    .font(Theme.label(20))
                    .foregroundStyle(Theme.yellow)
                    .wsShadow()
                Spacer()
                if total > 0 {
                    ViewerBadge(count: total, fontSize: 18, color: Theme.cyan)
                        .wsShadow()
                }
            }
            .padding(.horizontal, 16)
            .frame(width: Self.channelColumnWidth, height: 46)
            .background(Theme.headerPurple, ignoresSafeAreaEdges: [])
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.ringOuter).frame(width: 2)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Theme.headerPurple

                    ForEach(hours, id: \.self) { tickMs in
                        let pct = (tickMs - windowStartMs) / Self.windowDurationMs
                        let x = max(10, min(geo.size.width - 130, geo.size.width * pct))
                        Text(Theme.formatTime12(tickMs))
                            .font(Theme.label(20))
                            .foregroundStyle(.white)
                            .wsShadow()
                            .offset(x: x)
                    }

                    // Small yellow "now" marker tick on the bottom edge of the time header
                    if nowMs >= windowStartMs && nowMs <= windowEndMs {
                        let nowX = geo.size.width * ((nowMs - windowStartMs) / Self.windowDurationMs)
                        Rectangle()
                            .fill(Theme.yellow)
                            .frame(width: 3, height: 10)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .offset(x: nowX)
                    }

                    if windowStartMs > Self.currentHalfHourMs() {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "arrowtriangle.left.fill").font(.system(size: 10))
                                Text("EARLIER / LATER")
                                    .font(Theme.label(14))
                                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 10))
                            }
                            .foregroundStyle(Theme.cyan.opacity(0.9))
                            .padding(.trailing, 14)
                        }
                    }
                }
            }
            .frame(height: 46)
            .clipped()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.ringOuter).frame(height: 2)
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

    private func shiftWindow(bySteps steps: Int) {
        let floorMs = Self.currentHalfHourMs()
        let next = max(floorMs, max(floorMs, windowStartMs) + Double(steps) * Self.stepMs)
        if next != windowStartMs {
            windowStartMs = next
        }
    }
}

// MARK: - Single Channel Row

private struct GuideGridRow: View {
    @Environment(BroadcastStore.self) private var store
    let channel: ChannelInfo
    let isEven: Bool
    let isSelectedRow: Bool
    let windowStartMs: Double
    let windowEndMs: Double
    let nowMs: Double
    var focusedCell: FocusState<GuideGrid.GridCellID?>.Binding
    let onRowFocused: (ChannelInfo, GuideBlock?) -> Void
    let onCellActivate: (ChannelInfo, GuideBlock) -> Void
    let onShiftWindow: (Int) -> Void

    @State private var blocks: [GuideBlock] = []

    private var taskKey: String {
        "\(channel.id)|\(Int64(windowStartMs))|\(store.scheduleRevision)"
    }

    var body: some View {
        let rowBg = isEven ? Theme.deepNavy.opacity(0.92) : Theme.gridMidBlue.opacity(0.38)
        let viewers = store.presence.count(for: channel.id)

        HStack(spacing: 0) {
            // Pinned channel column
            HStack(spacing: 12) {
                Text(channel.dialText)
                    .font(Theme.dialNumber(32))
                    .foregroundStyle(isSelectedRow ? .white : Theme.yellow)
                    .wsShadow()
                    .frame(width: 62, alignment: .trailing)

                if let rows = channel.logomark?.rows, !rows.isEmpty {
                    LogomarkView(rows: rows, primaryColor: channel.color, size: 38)
                } else {
                    Text(channel.emoji ?? "📺")
                        .font(.system(size: 26))
                        .frame(width: 38, height: 38)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(Theme.channelName(18))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .wsShadow()
                    HStack(spacing: 8) {
                        if channel.comingSoon == true {
                            Text("COMING SOON")
                                .font(Theme.label(13))
                                .foregroundStyle(Theme.yellow)
                        } else if viewers > 0 {
                            ViewerBadge(count: viewers, fontSize: 15, color: isSelectedRow ? Theme.yellow : Theme.blueMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: GuideGrid.channelColumnWidth, height: GuideGrid.rowHeight)
            .background(isSelectedRow ? AnyShapeStyle(Theme.focusRowGradient) : AnyShapeStyle(Theme.panelBox.opacity(0.95)), ignoresSafeAreaEdges: [])
            .clipped()
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.ringOuter).frame(width: 2)
            }

            // Proportional program cells
            GeometryReader { geo in
                let totalMs = max(1, windowEndMs - windowStartMs)

                ZStack(alignment: .leading) {
                    rowBg

                    // Subtle "now" line behind cells so it never cuts across title text
                    if nowMs >= windowStartMs && nowMs <= windowEndMs {
                        let nowX = geo.size.width * ((nowMs - windowStartMs) / totalMs)
                        Rectangle()
                            .fill(Theme.yellow.opacity(0.35))
                            .frame(width: 2, height: GuideGrid.rowHeight)
                            .offset(x: nowX)
                            .allowsHitTesting(false)
                    }

                    if blocks.isEmpty {
                        Text(channel.comingSoon == true ? "COMING SOON" : "Loading schedule…")
                            .font(Theme.gridText(19))
                            .foregroundStyle(Theme.blueMuted.opacity(0.75))
                            .padding(.horizontal, 16)
                    } else {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
                            let clampedStart = max(block.startMs, windowStartMs)
                            let clampedEnd = min(block.endMs, windowEndMs)
                            let leftX = geo.size.width * ((clampedStart - windowStartMs) / totalMs)
                            let rawWidth = geo.size.width * (max(0, clampedEnd - clampedStart) / totalMs)
                            let width = max(0, rawWidth - min(2, rawWidth / 2))
                            let cellID = GuideGrid.GridCellID(channelID: channel.id, blockID: block.id)

                            Button {
                                onCellActivate(channel, block)
                            } label: {
                                GuideProgramCell(
                                    channelName: channel.name,
                                    block: block,
                                    isCurrent: block.isAiring(atMs: nowMs),
                                    isCellFocused: focusedCell.wrappedValue == cellID,
                                    isRowSelected: isSelectedRow,
                                    nowMs: nowMs
                                )
                                .frame(width: width, height: GuideGrid.rowHeight - 2)
                                .clipped()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(SpelunkrPlainFocusButtonStyle())
                            .disabled(!channel.isWatchable)
                            .focused(focusedCell, equals: cellID)
                            .onMoveCommand { direction in
                                if direction == .right && idx == blocks.count - 1 {
                                    onShiftWindow(1)
                                } else if direction == .left && idx == 0 {
                                    onShiftWindow(-1)
                                }
                            }
                            .offset(x: leftX)
                        }
                    }
                }
            }
            .frame(height: GuideGrid.rowHeight)
            .clipped()
        }
        .frame(height: GuideGrid.rowHeight)
        .clipped()
        .overlay(
            Rectangle()
                .stroke(isSelectedRow ? Theme.yellow : Theme.gridLine, lineWidth: isSelectedRow ? 3 : 1)
        )
        .task(id: taskKey) {
            let updated = await store.blocks(for: channel.id, fromMs: windowStartMs, toMs: windowEndMs)
            guard !Task.isCancelled else { return }
            blocks = updated
            // Focus the first watchable channel's active cell on initial load
            if focusedCell.wrappedValue == nil, isSelectedRow, let first = blocks.first {
                focusedCell.wrappedValue = GuideGrid.GridCellID(channelID: channel.id, blockID: first.id)
            }
        }
        .onChange(of: focusedCell.wrappedValue) { _, newValue in
            guard let newValue, newValue.channelID == channel.id else { return }
            let matched = blocks.first { $0.id == newValue.blockID }
            onRowFocused(channel, matched)
        }
    }
}

// MARK: - Program / Marathon Cell

private struct GuideProgramCell: View {
    let channelName: String
    let block: GuideBlock
    let isCurrent: Bool
    let isCellFocused: Bool
    let isRowSelected: Bool
    let nowMs: Double

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

        VStack(alignment: .leading, spacing: 4) {
            Text(primaryTitle)
                .font(Theme.gridText(21))
                .foregroundStyle(isCellFocused ? Theme.yellow : .white)
                .lineLimit(1)
                .truncationMode(.tail)
                .wsShadow()

            Text(subtitle)
                .font(Theme.label(15))
                .foregroundStyle(isCellFocused ? .white : (block.isMarathon ? Theme.cyan : Theme.blueMuted))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(cellBackground, ignoresSafeAreaEdges: [])
        .overlay(
            Rectangle()
                .stroke(isCellFocused ? Theme.yellow : Theme.ringOuter.opacity(0.65), lineWidth: isCellFocused ? 3 : 1)
        )
    }

    private var cellBackground: AnyShapeStyle {
        if isCellFocused {
            return AnyShapeStyle(Theme.focusRowGradient)
        }
        if isCurrent {
            return AnyShapeStyle(Color.white.opacity(isRowSelected ? 0.14 : 0.08))
        }
        return AnyShapeStyle(Theme.panelBox.opacity(0.55))
    }
}
