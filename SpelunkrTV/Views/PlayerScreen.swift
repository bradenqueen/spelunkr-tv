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

                if theme.usesCableLayout {
                    CablePlayerOverlay(channel: channel, item: tv.onAir)
                        .transition(.opacity)
                } else {
                    InfoBanner(
                        channel: channel,
                        item: tv.onAir,
                        blurb: blurb,
                        viewers: store.presence.count(for: channel.id)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
        .cableScanlines()
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

private struct CablePlayerOverlay: View {
    @Environment(\.appTheme) private var theme
    let channel: ChannelInfo
    let item: OnAir?

    var body: some View {
        VStack {
            VStack(alignment: .trailing, spacing: 4) {
                Text(channel.dialText).font(theme.dialNumber(82))
                Text(channel.name.uppercased()).font(theme.channelName(30)).lineLimit(1)
            }
            .foregroundStyle(theme.accent)
            .padding(22)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: theme.cellCornerRadius))
            .frame(maxWidth: .infinity, alignment: .trailing)

            Spacer()

            HStack(spacing: 26) {
                if let rows = channel.logomark?.rows, !rows.isEmpty {
                    LogomarkView(rows: rows, primaryColor: channel.color, size: 86)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    Text(channel.dialText).font(theme.dialNumber(50))
                    Text(channel.name.uppercased()).font(theme.label(26)).lineLimit(1)
                }
                .foregroundStyle(theme.accent)
                .frame(width: 265, alignment: .trailing)

                VStack(alignment: .leading, spacing: 8) {
                    Text(item?.displayTitle ?? "Tuning…")
                        .font(theme.heading(38)).foregroundStyle(theme.primaryText).lineLimit(1)
                    if let item {
                        if let year = item.year, !year.isEmpty {
                            Text(year).font(theme.label(24)).foregroundStyle(theme.mutedText)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let now = context.date.timeIntervalSince1970 * 1000
                            let duration = max(1, item.endMs - item.startMs)
                            let progress = min(1, max(0, (now - item.startMs) / duration))
                            ProgressView(value: progress)
                                .tint(theme.accent)
                                .accessibilityLabel("Program progress")
                            Text("\(Theme.formatTime12(item.startMs)) – \(Theme.formatTime12(item.endMs)) · \(formatDuration(item.secondsLeft(atMs: now))) left")
                                .font(theme.time(24)).foregroundStyle(theme.mutedText).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(26)
            .frame(maxWidth: 1440)
            .background(theme.baseSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: theme.panelCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: theme.panelCornerRadius)
                    .strokeBorder(theme.panelBorder, lineWidth: 2)
            }
        }
        .padding(.horizontal, 96)
        .padding(.vertical, 64)
        .allowsHitTesting(false)
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
        let floatsOverVideo = theme.playerBannerCornerRadius > 0
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
            .padding(.horizontal, floatsOverVideo ? 32 : 80)
            .padding(.top, floatsOverVideo ? 28 : 60)
            .padding(.bottom, 30)
            .background { bannerBackdrop(floating: floatsOverVideo) }
            // Keep the floating card inside the tvOS title-safe area.
            .padding(.horizontal, floatsOverVideo ? 80 : 0)
            .padding(.top, floatsOverVideo ? 60 : 0)
            Spacer()
        }
    }

    @ViewBuilder
    private func bannerBackdrop(floating: Bool) -> some View {
        if floating {
            let shape = RoundedRectangle(cornerRadius: theme.playerBannerCornerRadius)
            shape.fill(.regularMaterial)
                .overlay {
                    shape.fill(theme.brandSurface.opacity(0.9))
                }
                .overlay {
                    shape.strokeBorder(theme.panelBorder, lineWidth: theme.playerBorderWidth)
                }
        } else {
            Rectangle()
                .fill(LinearGradient(
                    colors: [theme.brandSurface.opacity(0.96), theme.baseSurface.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .ignoresSafeArea(edges: [.top, .horizontal])
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.panelBorder).frame(height: theme.playerBorderWidth)
                }
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
