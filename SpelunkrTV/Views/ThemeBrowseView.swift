import SwiftUI

struct BrowseFocusRequest: Equatable {
    let id = UUID()
    let target: GuideFocus
    var preferLiveProgram = false
}

struct ThemeBrowseView<Preview: View>: View {
    @Environment(\.appTheme) var theme
    @Environment(BroadcastStore.self) private var store
    let channels: [ChannelInfo]
    let selectedChannel: ChannelInfo?
    let focus: FocusState<GuideFocus?>.Binding
    @Binding var focusRequest: BrowseFocusRequest?
    let preview: () -> Preview
    let onWatch: (ChannelInfo) -> Void
    let onInspect: (ChannelInfo, GuideEntry) -> Void

    @State private var loadedSchedule: LoadedSchedule?

    private struct ScheduleRequest: Equatable {
        let channelID: String
        let revision: Int
        let halfHourStartMs: Double
    }

    private struct FocusWork: Equatable {
        let request: BrowseFocusRequest
        let waitingForSchedule: Bool
    }

    private struct LoadedSchedule {
        let channelID: String
        let programs: [GuideProgram]
    }

    private func scheduleRequest(now: Double) -> ScheduleRequest? {
        guard theme.guideLayout == .scheduleDesk, let channel = selectedChannel, channel.isWatchable else { return nil }
        return ScheduleRequest(
            channelID: channel.id,
            revision: store.scheduleRevision,
            halfHourStartMs: GuideGrid.currentHalfHourMs(from: now)
        )
    }

    var schedule: [GuideProgram] {
        guard loadedSchedule?.channelID == selectedChannel?.id else { return [] }
        return loadedSchedule?.programs ?? []
    }

    var isScheduleLoading: Bool {
        guard let scheduleRequest = scheduleRequest(now: Date.nowMs) else { return false }
        return loadedSchedule?.channelID != scheduleRequest.channelID
    }

    private var focusWork: FocusWork? {
        guard let focusRequest else { return nil }
        let scheduleChannelID: String?
        switch focusRequest.target {
        case .browseSchedule(let channelID, _):
            scheduleChannelID = channelID
        case .browseChannel(let channelID) where focusRequest.preferLiveProgram:
            scheduleChannelID = channelID
        default:
            scheduleChannelID = nil
        }
        let waitingForSchedule = scheduleChannelID != nil && scheduleChannelID == selectedChannel?.id && isScheduleLoading
        return FocusWork(request: focusRequest, waitingForSchedule: waitingForSchedule)
    }

    var body: some View {
        ScrollViewReader { proxy in
            TimelineView(.periodic(from: .now, by: theme.guideLayout == .scheduleDesk ? 1 : 60)) { context in
                let now = context.date.timeIntervalSince1970 * 1000
                let request = scheduleRequest(now: now)
                layout(now: now)
                    .task(id: request) { await loadSchedule(for: request) }
            }
            .task(id: focusWork) {
                guard let focusWork, !focusWork.waitingForSchedule else { return }
                defer {
                    if !Task.isCancelled, focusRequest == focusWork.request { focusRequest = nil }
                }
                let target = availableTarget(for: focusWork.request)
                proxy.scrollTo(target)
                for _ in 0..<4 {
                    await Task.yield()
                    guard !Task.isCancelled, focus.wrappedValue != target else { return }
                    focus.wrappedValue = target
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusSection()
    }

    private func loadSchedule(for request: ScheduleRequest?) async {
        guard let request else { return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let programs = await store.programs(
            for: request.channelID,
            fromMs: request.halfHourStartMs,
            toMs: request.halfHourStartMs + GuideGrid.stepMs + 86_400_000
        )
        guard !Task.isCancelled, store.scheduleRevision == request.revision else { return }
        loadedSchedule = LoadedSchedule(channelID: request.channelID, programs: programs)
    }

    @ViewBuilder
    private func layout(now: Double) -> some View {
        switch theme.guideLayout {
        case .daylight: daylight(now: now)
        case .cinema: cinema(now: now)
        case .channelWall: channelWall(now: now)
        case .scheduleDesk: scheduleDesk(now: now)
        case .largePrint: largePrint(now: now)
        case .spotlight: spotlight(now: now)
        case .timeline: EmptyView()
        }
    }

    func currentEntry(for channel: ChannelInfo, now: Double) -> GuideEntry? {
        store.guide[channel.id]?.first { $0.startMs <= now && now < $0.endMs }
    }

    func nextEntry(for channel: ChannelInfo, now: Double) -> GuideEntry? {
        store.guide[channel.id]?.first { $0.startMs > now }
    }

    func stationLabel(for channel: ChannelInfo, now: Double, includeNext: Bool = false) -> String {
        var parts = ["Channel \(channel.dialText)", channel.name]
        if !channel.isWatchable {
            parts.append("Coming soon")
        } else {
            if let entry = currentEntry(for: channel, now: now) {
                parts.append("Live, \(entry.title), \(formatClock(entry.startMs))")
            } else {
                parts.append("No current listing")
            }
            if includeNext, let next = nextEntry(for: channel, now: now) {
                parts.append("Next, \(next.title), \(formatClock(next.startMs))")
            }
        }
        return parts.joined(separator: ", ")
    }

    func browseButton<Label: View>(
        channel: ChannelInfo,
        target: GuideFocus,
        accessibilityLabel: String,
        opensDetails: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let isSelected = selectedChannel?.id == channel.id && target == .browseChannel(channel.id)
        return Button(action: action, label: label)
            .buttonStyle(SpelunkrActionButtonStyle(
                background: isSelected ? theme.selectedRowFill : AnyShapeStyle(theme.panelFill),
                restingBorder: isSelected ? theme.selectedBorder : theme.controlBorder,
                horizontalPadding: 0,
                verticalPadding: 0
            ))
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(opensDetails ? Text("Shows program details") : Text("Watches this channel live"))
            .disabled(!channel.isWatchable)
            .opacity(channel.isWatchable ? 1 : 0.65)
            .focused(focus, equals: target)
            .id(target)
    }

    @ViewBuilder
    func channelMark(_ channel: ChannelInfo, size: CGFloat) -> some View {
        if let rows = channel.logomark?.rows, !rows.isEmpty {
            LogomarkView(rows: rows, primaryColor: channel.color, size: size)
                .accessibilityHidden(true)
        } else {
            Text(channel.emoji ?? "📺")
                .font(.system(size: size * 0.72))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private func availableTarget(for request: BrowseFocusRequest) -> GuideFocus {
        let target = request.target
        let channelID: String
        switch target {
        case .browseChannel(let id), .browseUpcoming(let id, _), .browseSchedule(let id, _):
            channelID = id
        default:
            return target
        }
        guard let channel = channels.first(where: { $0.id == channelID && $0.isWatchable }) else {
            return channels.first(where: \.isWatchable).map { .browseChannel($0.id) } ?? .fullGuide
        }
        let now = Date.nowMs
        if request.preferLiveProgram, theme.guideLayout == .scheduleDesk,
           let program = schedule.first(where: { $0.isAiring(atMs: now) }) {
            return .browseSchedule(channelID, program.id)
        }
        switch target {
        case .browseUpcoming(_, let startMs) where theme.guideLayout == .spotlight:
            if nextEntry(for: channel, now: now)?.startMs == startMs { return target }
        case .browseSchedule(_, let programID) where theme.guideLayout == .scheduleDesk:
            if schedule.contains(where: { $0.id == programID && $0.endMs > now }) { return target }
        default:
            break
        }
        return .browseChannel(channelID)
    }
}
