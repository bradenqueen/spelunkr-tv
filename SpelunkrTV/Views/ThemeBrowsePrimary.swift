import SwiftUI

extension ThemeBrowseView {
    func daylight(now: Double) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 36) {
                preview()
                    .frame(width: 416, height: 234)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 12) {
                    Text(selectedChannel?.name ?? "Channel guide")
                        .font(theme.label(24))
                        .foregroundStyle(theme.accent)
                    Text(selectedProgramTitle(now: now))
                        .font(.system(size: 48, weight: .medium, design: .serif))
                        .lineLimit(2)
                    if let channel = selectedChannel, let next = nextEntry(for: channel, now: now) {
                        Text("Next · \(formatClock(next.startMs)) · \(next.title)")
                            .font(theme.body(28))
                            .foregroundStyle(theme.softText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 26) {
                Text("Channel").frame(width: 392, alignment: .leading)
                Text("Now").frame(maxWidth: .infinity, alignment: .leading)
                Text("Next").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(theme.label(22))
            .foregroundStyle(theme.mutedText)
            .padding(.horizontal, 30)
            Rectangle().fill(theme.gridLine).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(channels) { channel in
                        browseButton(channel: channel, target: .browseChannel(channel.id),
                                     accessibilityLabel: stationLabel(for: channel, now: now, includeNext: true), action: { onWatch(channel) }) {
                            HStack(spacing: 26) {
                                HStack(spacing: 16) {
                                    channelMark(channel, size: 52)
                                    Text(channel.dialText).font(theme.time(24)).foregroundStyle(theme.mutedText)
                                    Text(channel.name).font(theme.channelName(26))
                                }
                                .frame(width: 392, alignment: .leading)
                                Text(programTitle(for: channel, now: now))
                                    .font(theme.body(26))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(channel.isWatchable ? nextEntry(for: channel, now: now)?.title ?? "No listing" : "—")
                                    .font(theme.body(24))
                                    .foregroundStyle(theme.softText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .lineLimit(2)
                            .padding(.horizontal, 24)
                            .frame(minHeight: 92)
                        }
                    }
                }
                .padding(6)
            }
        }
        .foregroundStyle(theme.primaryText)
    }

    func cinema(now: Double) -> some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 20) {
                preview()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let channel = selectedChannel {
                    Text("CH \(channel.dialText)   ·   \(channel.name)")
                        .font(theme.label(25))
                        .foregroundStyle(theme.accent)
                }
                Text(selectedProgramTitle(now: now))
                    .font(theme.heading(42))
                    .lineLimit(3, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                Text("Channels").font(theme.heading(29)).padding(.leading, 8)
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(channels) { channel in
                            browseButton(channel: channel, target: .browseChannel(channel.id),
                                         accessibilityLabel: stationLabel(for: channel, now: now), action: { onWatch(channel) }) {
                                HStack(spacing: 14) {
                                    channelMark(channel, size: 52)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(channel.dialText)  \(channel.name)").font(theme.channelName(24))
                                        Text(programTitle(for: channel, now: now))
                                            .font(theme.body(25))
                                            .foregroundStyle(theme.softText)
                                    }
                                    .lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(16)
                                .frame(minHeight: 96)
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 470)
        }
        .foregroundStyle(theme.primaryText)
    }

    func channelWall(now: Double) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 34) {
                preview()
                    .frame(width: 448, height: 252)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 10) {
                    if let channel = selectedChannel {
                        Text("CH \(channel.dialText)   ·   \(channel.name)")
                            .font(theme.label(26))
                            .foregroundStyle(theme.accent)
                    }
                    Text(selectedProgramTitle(now: now)).font(theme.heading(42)).lineLimit(3, reservesSpace: true)
                }
                Spacer(minLength: 0)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 4), spacing: 18) {
                    ForEach(channels) { channel in
                        browseButton(channel: channel, target: .browseChannel(channel.id),
                                     accessibilityLabel: stationLabel(for: channel, now: now), action: { onWatch(channel) }) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    channelMark(channel, size: 68)
                                    Spacer()
                                    Text(channel.dialText)
                                        .font(theme.dialNumber(34))
                                        .foregroundStyle(theme.accent)
                                }
                                Text(channel.name).font(theme.channelName(28)).lineLimit(1)
                                Text(programTitle(for: channel, now: now))
                                    .font(theme.body(25))
                                    .foregroundStyle(theme.softText)
                                    .lineLimit(1)
                            }
                            .padding(22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(6)
            }
        }
        .foregroundStyle(theme.primaryText)
    }

    private func selectedProgramTitle(now: Double) -> String {
        selectedChannel.map { programTitle(for: $0, now: now) } ?? "No channel selected"
    }

    private func programTitle(for channel: ChannelInfo, now: Double) -> String {
        guard channel.isWatchable else { return "Coming soon" }
        return currentEntry(for: channel, now: now)?.title ?? "No current listing"
    }
}
