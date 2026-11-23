import SwiftUI

/// The channel guide: every channel, what's on now, and what's next.
struct GuideView: View {
    @Environment(BroadcastStore.self) private var store
    let initialFocus: String?
    let onSelect: (ChannelInfo) -> Void

    @FocusState private var focused: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                    .padding(.bottom, 20)
                ForEach(store.channels) { channel in
                    Button {
                        onSelect(channel)
                    } label: {
                        GuideRow(channel: channel, entries: store.guide[channel.id] ?? [])
                    }
                    .buttonStyle(GuideRowStyle(tint: channel.tint))
                    .disabled(!channel.isWatchable)
                    .focused($focused, equals: channel.id)
                }
                Text("ALL PROGRAMMING COURTESY OF THE INTERNET ARCHIVE · SPELUNKR.TV")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .background(
            LinearGradient(colors: [.spelunkrPurple, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .defaultFocus($focused, initialFocus ?? store.watchableChannels.first?.id)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SPELUNKR")
                    .font(.system(size: 76, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.yellow)
                Text("cable tv, but weirder. \(store.channels.count) channels, always live.")
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                if let warning = store.engineWarning {
                    Text(warning)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct GuideRow: View {
    let channel: ChannelInfo
    let entries: [GuideEntry]

    var body: some View {
        let now = Date.nowMs
        let current = entries.first { $0.startMs <= now && now < $0.endMs }
        let upcoming = entries.first { $0.startMs > now }

        HStack(spacing: 28) {
            Text(channel.dialText)
                .font(.system(size: 40, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 112, height: 84)
                .background(channel.tint, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(channel.emoji ?? "") \(channel.name)")
                    .font(.system(size: 30, weight: .heavy, design: .monospaced))
                    .lineLimit(1)
                if channel.comingSoon == true {
                    Text("COMING SOON")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)
                }
            }
            .frame(width: 430, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if let current {
                    Text(titleLine(current))
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(1)
                    ProgressView(value: min(1, max(0, (now - current.startMs) / (current.endMs - current.startMs))))
                        .tint(channel.tint)
                } else {
                    Text("Station break")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                if let upcoming {
                    Text("NEXT · \(formatClock(upcoming.startMs))")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(upcoming.title)
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .frame(width: 420, alignment: .leading)
        }
        .foregroundStyle(.white)
    }

    private func titleLine(_ e: GuideEntry) -> String {
        if let year = e.year { return "\(e.title) (\(year))" }
        return e.title
    }
}

struct GuideRowStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        GuideRowBody(configuration: configuration, tint: tint)
    }
}

private struct GuideRowBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isFocused ? tint.opacity(0.35) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isFocused ? Color.white.opacity(0.9) : .clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.02 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
