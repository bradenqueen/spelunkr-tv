import SwiftUI

extension ThemeBrowseView {
    func scheduleDesk(now: Double) -> some View {
        HStack(alignment: .top, spacing: 38) {
            VStack(alignment: .leading, spacing: 16) {
                deskHeading("Stations")
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(channels) { channel in
                            browseButton(channel: channel, target: .browseChannel(channel.id),
                                         accessibilityLabel: stationLabel(for: channel, now: now), action: { onWatch(channel) }) {
                                HStack(spacing: 16) {
                                    Text(channel.dialText).font(.system(size: 25, weight: .bold, design: .monospaced))
                                    Text(channel.name).font(.system(size: 27, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    if selectedChannel?.id == channel.id {
                                        Image(systemName: "chevron.right").foregroundStyle(theme.accent)
                                    }
                                }
                                .padding(18)
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(width: 460)
            Divider().overlay(theme.panelBorder)
            VStack(alignment: .leading, spacing: 16) {
                deskHeading(selectedChannel.map { "\($0.name) · Next 24 hours" } ?? "Next 24 hours")
                if let channel = selectedChannel {
                    let programs = schedule.filter { $0.endMs > now && $0.startMs < now + 86_400_000 }
                    let focusedProgram = programs.first { focus.wrappedValue == .browseSchedule(channel.id, $0.id) }
                    if let detail = focusedProgram ?? programs.first(where: { $0.isAiring(atMs: now) }) ?? programs.first {
                        Text("\(formatClock(detail.startMs)) · \(detail.title)")
                            .font(theme.heading(32))
                            .lineLimit(3, reservesSpace: true)
                            .padding(.horizontal, 10)
                            .accessibilityHidden(true)
                    }
                    if programs.isEmpty {
                        Text(isScheduleLoading ? "Loading schedule…" : "Schedule unavailable")
                            .foregroundStyle(theme.softText).padding()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(programs) { program in
                                    let live = program.isAiring(atMs: now)
                                    let state = live ? "Live" : "Upcoming"
                                    let label = "Channel \(channel.dialText), \(channel.name), \(state), \(program.title), \(formatClock(program.startMs))"
                                    browseButton(channel: channel, target: .browseSchedule(channel.id, program.id),
                                                 accessibilityLabel: label, opensDetails: !live, action: {
                                        let activationTime = Date.nowMs
                                        if program.endMs <= activationTime {
                                            focusRequest = BrowseFocusRequest(target: .browseChannel(channel.id), preferLiveProgram: true)
                                        } else if program.isAiring(atMs: activationTime) {
                                            onWatch(channel)
                                        } else {
                                            onInspect(channel, GuideEntry(title: program.title, year: program.year,
                                                startMs: program.startMs, endMs: program.endMs,
                                                videoIndex: program.videoIndex, version: program.version))
                                        }
                                    }) {
                                        HStack(spacing: 24) {
                                            Text(formatClock(program.startMs)).monospacedDigit().frame(width: 160, alignment: .leading)
                                            Text(program.title).fontWeight(.semibold).lineLimit(2)
                                            Spacer()
                                            if live {
                                                Text("LIVE").font(.system(size: 21, weight: .heavy))
                                                    .foregroundStyle(theme.liveBadgeAccent)
                                            }
                                        }
                                        .font(.system(size: 29)).padding(20)
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.primaryText)
    }

    private func deskHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 36, weight: .semibold, design: .serif))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            .accessibilityAddTraits(.isHeader)
    }


    func largePrint(now: Double) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(channels) { channel in
                    browseButton(channel: channel, target: .browseChannel(channel.id),
                                 accessibilityLabel: stationLabel(for: channel, now: now), action: { onWatch(channel) }) {
                        HStack(spacing: 38) {
                            Text(channel.dialText)
                                .font(.system(size: 60, weight: .black, design: .monospaced))
                                .frame(minWidth: 120)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(channel.name).font(.system(size: 46, weight: .bold))
                                Text(channel.isWatchable ? currentEntry(for: channel, now: now)?.title ?? "Schedule unavailable" : "Coming soon")
                                    .font(.system(size: 38, weight: .medium))
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 32).padding(.vertical, 20)
                    }
                }
            }
            .padding(12)
        }
    }

    func spotlight(now: Double) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if let channel = selectedChannel {
                let entry = spotlightDetail(for: channel, now: now)
                let time = entry.map { " · " + formatClock($0.startMs) } ?? ""
                Text("\(channel.name)\(time) · \(entry?.title ?? "Schedule unavailable")")
                    .font(theme.heading(32))
                    .lineLimit(3, reservesSpace: true)
                    .padding(.leading, 10)
                    .accessibilityHidden(true)
            }
            spotlightRail(upcoming: false, now: now)
            spotlightRail(upcoming: true, now: now)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func spotlightDetail(for channel: ChannelInfo, now: Double) -> GuideEntry? {
        if case let .browseUpcoming(id, _)? = focus.wrappedValue, id == channel.id {
            return nextEntry(for: channel, now: now)
        }
        return currentEntry(for: channel, now: now)
    }

    private func spotlightRail(upcoming: Bool, now: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(upcoming ? "Up Next" : "On Now")
                .font(.system(size: 42, weight: .black)).foregroundStyle(theme.primaryText)
                .padding(.leading, 10)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 22) {
                    ForEach(channels) { channel in
                        let entry = upcoming ? nextEntry(for: channel, now: now) : currentEntry(for: channel, now: now)
                        let target: GuideFocus = upcoming ? .browseUpcoming(channel.id, entry?.startMs ?? 0) : .browseChannel(channel.id)
                        let upcomingListing = entry.map { "\($0.title), \(formatClock($0.startMs))" } ?? "Schedule unavailable"
                        let label = upcoming
                            ? "Channel \(channel.dialText), \(channel.name), upcoming, \(upcomingListing)"
                            : stationLabel(for: channel, now: now)
                        browseButton(channel: channel, target: target, accessibilityLabel: label,
                                     opensDetails: upcoming, action: {
                            if upcoming {
                                if let entry { onInspect(channel, entry) }
                            } else {
                                onWatch(channel)
                            }
                        }) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 12) {
                                    channelMark(channel, size: 38)
                                    Text("\(channel.dialText)  \(channel.name)").lineLimit(1)
                                        .font(.system(size: 23, weight: .semibold))
                                }
                                Spacer(minLength: 4)
                                Text(entry?.title ?? (channel.isWatchable ? "Schedule unavailable" : "Coming soon"))
                                    .font(.system(size: 34, weight: .bold)).lineLimit(2)
                                if let entry {
                                    Text(formatClock(entry.startMs)).font(.system(size: 24, weight: .medium)).monospacedDigit()
                                }
                            }
                            .foregroundStyle(theme.primaryText)
                            .padding(22).frame(width: 390, height: 200, alignment: .leading)
                        }
                        .disabled(upcoming && entry == nil)
                    }
                }
                .padding(10)
            }
        }
    }
}
