import AVFoundation
import SwiftUI
import UIKit

/// Full-screen TV. Siri Remote: up/down change channel, click or play/pause shows info,
/// Menu/Back returns to the guide without interrupting playback.
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
                StaticView(caption: tv.channel.map { "CH \($0.dialText) - \($0.name)" } ?? "")
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
                    Text("TRACKING...")
                        .font(Theme.heading(28))
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 80)
                }
            }

            if showInfo, let channel = tv.channel {
                let _ = store.detailsRevision
                let blurb = store.detail(
                    channelID: channel.id,
                    version: tv.onAir?.version,
                    videoIndex: tv.onAir?.videoIndex
                )?.description

                InfoBanner(
                    channel: channel,
                    item: tv.onAir,
                    blurb: blurb,
                    viewers: store.presence.count(for: channel.id)
                )
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
            if let ch = tv.channel {
                store.presence.track(channelID: ch.id)
                Task { await store.ensureDetails(for: ch) }
            }
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
        .onChange(of: tv.channel?.id) { _, _ in
            if let ch = tv.channel {
                Task { await store.ensureDetails(for: ch) }
            }
        }
    }

    private func changeChannel(by delta: Int) {
        let list = store.watchableChannels
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == tv.channel?.id } ?? 0
        let next = list[(index + delta + list.count) % list.count]
        tv.tune(next)
        store.presence.track(channelID: next.id)
        flashInfo()
    }

    private func flashInfo() {
        withAnimation(.easeOut(duration: 0.2)) { showInfo = true }
        infoToken += 1
        let token = infoToken
        Task {
            try? await Task.sleep(for: .seconds(6))
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
    var blurb: String? = nil
    var viewers: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: 4) {
                    Text(channel.dialText)
                        .font(Theme.dialNumber(58))
                        .foregroundStyle(Theme.yellow)
                        .wsShadow()
                }
                .frame(width: 148, height: 112)
                .background(Theme.panelBox, ignoresSafeAreaEdges: [])
                .overlay(Rectangle().stroke(Theme.ringOuter, lineWidth: 3))
                .overlay(Rectangle().stroke(Theme.ringInner, lineWidth: 2).padding(3))

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        if let rows = channel.logomark?.rows, !rows.isEmpty {
                            LogomarkView(rows: rows, primaryColor: channel.color, size: 38)
                        }
                        Text(channel.name)
                            .font(Theme.channelName(30))
                            .foregroundStyle(Theme.yellow)
                            .wsShadow()
                        if let fam = channel.family { FamilyBadge(family: fam) }
                        LiveBadge()
                        if viewers > 0 {
                            ViewerBadge(count: viewers, suffix: "WATCHING", fontSize: 18, color: Theme.softText)
                        }
                    }

                    if let item {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(item.displayTitle)
                                .font(Theme.heading(42))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .wsShadow()
                            if item.type == "video", let year = item.year, !year.isEmpty {
                                Text(year)
                                    .font(Theme.label(24))
                                    .foregroundStyle(Theme.cyan)
                            }
                        }

                        if let blurb, !blurb.isEmpty {
                            Text(blurb)
                                .font(Theme.body(22))
                                .foregroundStyle(Theme.softText)
                                .lineLimit(2)
                        }

                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let nowMs = Date.nowMs
                            let totalS = max(1, (item.endMs - item.startMs) / 1000)
                            let elapsedS = max(0, min(totalS, (nowMs - item.startMs) / 1000))
                            let leftS = item.secondsLeft(atMs: nowMs)

                            VStack(alignment: .leading, spacing: 8) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(Theme.deepNavy)
                                        Rectangle()
                                            .fill(Theme.progressFill)
                                            .frame(width: geo.size.width * (elapsedS / totalS))
                                    }
                                    .overlay(Rectangle().stroke(Theme.borderLight.opacity(0.8), lineWidth: 1))
                                }
                                .frame(height: 10)
                                .frame(maxWidth: 720)

                                HStack(spacing: 18) {
                                    Text("\(formatDuration(leftS)) LEFT")
                                        .font(Theme.label(22))
                                        .foregroundStyle(Theme.yellow)
                                    if let next = item.next {
                                        Text("NEXT AT \(Theme.formatTime12(next.startMs)): \(next.title)")
                                            .font(Theme.body(22))
                                            .foregroundStyle(Theme.cyan)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Tuning...")
                            .font(Theme.heading(40))
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
            }
            .foregroundStyle(.white)
            // tvOS title-safe margins
            .padding(.horizontal, 80)
            .padding(.top, 56)
            .padding(.bottom, 34)
            .background(
                LinearGradient(
                    colors: [Theme.brandPurple.opacity(0.96), Theme.deepNavy.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                ignoresSafeAreaEdges: [.top, .horizontal]
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.ringOuter).frame(height: 3)
            }
            Spacer()
        }
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
