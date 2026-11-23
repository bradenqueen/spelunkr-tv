import AVFoundation
import SwiftUI
import UIKit

/// Full-screen TV. Siri Remote: up/down change channel, click or play/pause shows info,
/// Menu/Back returns to the guide without interrupting playback.
struct PlayerScreen: View {
    @Environment(BroadcastStore.self) private var store
    @Environment(\.appTheme) private var theme
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
                        .font(theme.heading(32))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(
                            theme.bufferingBackground,
                            in: RoundedRectangle(cornerRadius: theme.bufferingCornerRadius)
                        )
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
        .defaultFocus($focused, true)
        .onAppear {
            tv.setFullscreen(true)
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
            tv.setFullscreen(false)
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
            // Any channel change in full screen (including one made elsewhere) shows the banner.
            flashInfo()
            if let ch = tv.channel {
                Task { await store.ensureDetails(for: ch) }
            }
        }
        .onChange(of: tv.phase) { old, new in
            // A slow tune can outlast the banner's timer: show it again when the picture arrives.
            if new == .playing, old != .playing { flashInfo() }
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
    @Environment(\.appTheme) private var theme
    let channel: ChannelInfo
    let item: OnAir?
    var blurb: String? = nil
    var viewers: Int = 0

    var body: some View {
        let dialShape = RoundedRectangle(cornerRadius: theme.controlCornerRadius)
        let progressShape = RoundedRectangle(cornerRadius: min(5, theme.controlCornerRadius))

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 4) {
                    Text(channel.dialText)
                        .font(theme.dialNumber(76))
                        .foregroundStyle(theme.accent)
                        .wsShadow()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: 176, height: 128)
                .background(theme.raisedSurface, in: dialShape)
                .overlay(dialShape.stroke(theme.panelBorder, lineWidth: theme.playerBorderWidth))
                .overlay {
                    if theme.panelInnerBorderWidth > 0 {
                        dialShape.stroke(theme.panelInnerBorder, lineWidth: theme.panelInnerBorderWidth)
                            .padding(theme.playerBorderWidth)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        if let rows = channel.logomark?.rows, !rows.isEmpty {
                            LogomarkView(rows: rows, primaryColor: channel.color, size: 48)
                        }
                        Text(channel.name)
                            .font(theme.channelName(34))
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .wsShadow()
                        if let fam = channel.family { FamilyBadge(family: fam) }
                        LiveBadge()
                        if viewers > 0 {
                            ViewerBadge(count: viewers, suffix: "WATCHING", fontSize: 23, color: theme.softText)
                        }
                    }

                    if let item {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(item.displayTitle)
                                .font(theme.heading(50))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .wsShadow()
                            if item.type == "video", let year = item.year, !year.isEmpty {
                                Text(year)
                                    .font(theme.label(28))
                                    .foregroundStyle(theme.secondaryAccent)
                            }
                        }

                        if let blurb, !blurb.isEmpty {
                            Text(blurb)
                                .font(theme.body(26))
                                .foregroundStyle(theme.softText)
                                .lineLimit(2)
                                .shadow(color: .black.opacity(0.8), radius: 0, x: 1, y: 1)
                        }

                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let nowMs = Date.nowMs
                            let totalS = max(1, (item.endMs - item.startMs) / 1000)
                            let elapsedS = max(0, min(totalS, (nowMs - item.startMs) / 1000))
                            let leftS = item.secondsLeft(atMs: nowMs)

                            VStack(alignment: .leading, spacing: 8) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(theme.baseSurface)
                                        Rectangle()
                                            .fill(theme.progressFill)
                                            .frame(width: geo.size.width * (elapsedS / totalS))
                                    }
                                    .clipShape(progressShape)
                                    .overlay(progressShape.stroke(theme.controlBorder.opacity(0.8), lineWidth: 1))
                                }
                                .frame(height: 10)
                                .frame(maxWidth: 900)

                                HStack(spacing: 18) {
                                    Text("\(formatDuration(leftS)) LEFT")
                                        .font(theme.time(25))
                                        .foregroundStyle(theme.accent)
                                        .fixedSize()
                                    if let next = item.next {
                                        Text("NEXT AT \(Theme.formatTime12(next.startMs)): \(next.title)")
                                            .font(theme.body(25))
                                            .foregroundStyle(theme.secondaryAccent)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Tuning...")
                            .font(theme.heading(48))
                    }
                }
                Spacer()
            }
            .foregroundStyle(theme.primaryText)
            // tvOS title-safe margins
            .padding(.horizontal, 80)
            .padding(.top, 60)
            .padding(.bottom, 30)
            .background(
                LinearGradient(
                    colors: [theme.brandSurface.opacity(0.96), theme.baseSurface.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                ignoresSafeAreaEdges: [.top, .horizontal]
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.panelBorder).frame(height: theme.playerBorderWidth)
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
