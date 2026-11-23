import AVFoundation
import SwiftUI
import UIKit

/// Full-screen TV. Siri Remote: up/down change channel, click or play/pause shows info,
/// Menu/Back returns to the guide.
struct PlayerScreen: View {
    @Environment(BroadcastStore.self) private var store
    let tv: TVPlayer
    let onExit: () -> Void

    @State private var showInfo = true
    @State private var infoToken = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black

            PlayerLayerView(player: tv.video, correction: tv.correction, videoSize: tv.videoSize)
                .opacity(tv.phase == .playing ? 1 : 0)

            switch tv.phase {
            case .idle, .tuning:
                StaticView(caption: tv.channel.map { "CH \($0.dialText) · \($0.name)" } ?? "")
            case .card:
                if let item = tv.onAir, let channel = tv.channel {
                    BumpCardView(item: item, channel: channel)
                }
            case .problem(let message):
                StaticView(caption: message)
            case .playing:
                EmptyView()
            }

            if tv.phase == .playing && tv.isBuffering {
                VStack {
                    Spacer()
                    Text("TRACKING…")
                        .font(.system(size: 28, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 80)
                }
            }

            if showInfo, let channel = tv.channel {
                InfoBanner(channel: channel, item: tv.onAir)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            flashInfo()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            DisplayMatching.reset()
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: changeChannel(by: 1)
            case .down: changeChannel(by: -1)
            default: flashInfo()
            }
        }
        .onPlayPauseCommand { flashInfo() }
        .onTapGesture { flashInfo() }
        .onExitCommand { onExit() }
        .onChange(of: tv.onAir?.key) { _, _ in
            if tv.onAir?.type == "video" { flashInfo() }
        }
    }

    private func changeChannel(by delta: Int) {
        let list = store.watchableChannels
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == tv.channel?.id } ?? 0
        let next = list[(index + delta + list.count) % list.count]
        tv.tune(next)
        flashInfo()
    }

    private func flashInfo() {
        withAnimation(.easeOut(duration: 0.2)) { showInfo = true }
        infoToken += 1
        let token = infoToken
        Task {
            try? await Task.sleep(for: .seconds(5))
            if token == infoToken {
                withAnimation(.easeIn(duration: 0.4)) { showInfo = false }
            }
        }
    }
}

/// The "what am I watching" banner at the top of the screen.
struct InfoBanner: View {
    let channel: ChannelInfo
    let item: OnAir?

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 28) {
                Text(channel.dialText)
                    .font(.system(size: 64, weight: .heavy, design: .monospaced))
                    .frame(width: 150, height: 110)
                    .background(channel.tint, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Text("\(channel.emoji ?? "") \(channel.name)")
                        .font(.system(size: 30, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    if let item {
                        Text(titleLine(item))
                            .font(.system(size: 40, weight: .bold))
                            .lineLimit(2)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(detailLine(item))
                                .font(.system(size: 24, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        Text("Tuning…")
                            .font(.system(size: 40, weight: .bold))
                    }
                }
                Spacer()
            }
            .foregroundStyle(.white)
            // tvOS title-safe margins
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .background(
                LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            )
            Spacer()
        }
    }

    private func titleLine(_ item: OnAir) -> String {
        if item.type == "video", let year = item.year { return "\(item.displayTitle) (\(year))" }
        return item.displayTitle
    }

    private func detailLine(_ item: OnAir) -> String {
        var parts = ["\(formatDuration(item.secondsLeft(atMs: Date.nowMs))) left"]
        if let next = item.next { parts.append("next: \(next.title) at \(formatClock(next.startMs))") }
        return parts.joined(separator: "  ·  ")
    }
}

/// AVPlayerLayer without the system transport controls (live TV can't be scrubbed).
/// It also applies spelunkr.tv's per-tape picture fixes: squeezed tapes are stretched back to
/// their real shape, and tapes with a black border baked into the picture are zoomed to fill.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var correction: PictureCorrection = .none
    var videoSize: CGSize = .zero

    final class PlayerUIView: UIView {
        let playerLayer = AVPlayerLayer()
        private let clip = CALayer()
        var correction = PictureCorrection.none
        var videoSize = CGSize.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clip.backgroundColor = UIColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyLayout()
        }

        func update(correction: PictureCorrection, videoSize: CGSize) {
            guard correction != self.correction || videoSize != self.videoSize else { return }
            self.correction = correction
            self.videoSize = videoSize
            applyLayout()
        }

        private func applyLayout() {
            let placement = PictureGeometry.layout(container: bounds.size, video: videoSize, correction: correction)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.setAffineTransform(.identity)   // reset first: a frame can't be set under a transform
            playerLayer.frame = placement.frame
            playerLayer.videoGravity = placement.fill ? .resize : .resizeAspect
            if let visible = placement.visible {
                clip.frame = visible
                playerLayer.mask = clip
            } else {
                playerLayer.mask = nil
            }
            playerLayer.setAffineTransform(placement.transform)
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.update(correction: correction, videoSize: videoSize)
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.update(correction: correction, videoSize: videoSize)
    }
}
