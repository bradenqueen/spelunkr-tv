import SwiftUI

/// Station-ID and "up next" cards between shows, timed like spelunkr.tv's own cards.
struct BumpCardView: View {
    let item: OnAir
    let channel: ChannelInfo

    private enum Frame: Equatable {
        case intro            // channel name card
        case words(String)    // one slide of text
        case brand            // SPELUNKR card between the channel's and spelunkr's halves
        case upNext
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = context.date.timeIntervalSince1970 * 1000 - item.startMs
            card(for: frame(atMs: elapsed))
        }
    }

    // Slide timing from the site: each slide holds for max(2.5 s, 1.5 s + 55 ms per character).
    private static func slideMs(_ text: String) -> Double { max(2500, 1500 + Double(text.count) * 55) }

    private func frame(atMs elapsed: Double) -> Frame {
        if item.type == "up-next" { return .upNext }
        let channelSlides = item.channelSlides ?? []
        let platformSlides = item.platformSlides ?? []

        var timeline: [(Frame, Double)] = []
        if item.half != "close" {
            timeline.append((.intro, 3500))
            timeline += channelSlides.map { (Frame.words($0), Self.slideMs($0)) }
        }
        if item.half == nil && !platformSlides.isEmpty {
            timeline.append((.brand, 2300))
        }
        if item.half != "open" {
            timeline += platformSlides.map { (Frame.words($0), Self.slideMs($0)) }
        }

        var t = 0.0
        for (frame, length) in timeline {
            t += length
            if elapsed < t { return frame }
        }
        return timeline.last?.0 ?? .intro
    }

    private var musicCredit: String? {
        guard let audio = item.audio, let title = audio.title else { return nil }
        if let artist = audio.artist { return "♪ " + title + " · " + artist }
        return "♪ " + title
    }

    @ViewBuilder
    private func card(for frame: Frame) -> some View {
        ZStack {
            LinearGradient(colors: [channel.tint.opacity(0.85), .spelunkrPurple, .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            switch frame {
            case .intro:
                VStack(spacing: 24) {
                    Text(channel.emoji ?? "📺").font(.system(size: 140))
                    Text(channel.name)
                        .font(.system(size: 96, weight: .heavy, design: .monospaced))
                    Text("CHANNEL \(channel.dialText)")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .words(let text):
                Text(text)
                    .font(.system(size: 72, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 180)
                    .id(text)
                    .transition(.opacity)
            case .brand:
                Text("SPELUNKR")
                    .font(.system(size: 130, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.yellow)
            case .upNext:
                VStack(spacing: 20) {
                    Text("UP NEXT")
                        .font(.system(size: 44, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.yellow)
                    Text(item.next?.title ?? channel.name)
                        .font(.system(size: 80, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 160)
                }
            }

            if let credit = musicCredit {
                VStack {
                    Spacer()
                    Text(credit)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 60)
                }
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.4), value: frame)
    }
}

/// App status screen for loading, tuning and dead air.
struct StaticView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let caption: String

    var body: some View {
        ZStack {
            if theme.showsAnimatedStatic && !reduceMotion {
                animatedStatic
            } else {
                theme.screenBackground
            }

            Text(caption)
                .font(theme.statusCaptionFont)
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30).padding(.vertical, 18)
                .background(
                    theme.statusCaptionBackground,
                    in: RoundedRectangle(cornerRadius: theme.statusCaptionCornerRadius)
                )
                .padding(.horizontal, 160)
        }
        .ignoresSafeArea()
    }

    private var animatedStatic: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
            Canvas { context, size in
                let cell: CGFloat = 8
                let cols = Int(size.width / cell) + 1
                let rows = Int(size.height / cell) + 1
                for _ in 0..<2400 {
                    let x = CGFloat(Int.random(in: 0..<cols)) * cell
                    let y = CGFloat(Int.random(in: 0..<rows)) * cell
                    let g = Double.random(in: 0.25...0.9)
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                 with: .color(Color(white: g)))
                }
            }
        }
        .background(Color(white: 0.12))
        .opacity(0.55)
    }
}
