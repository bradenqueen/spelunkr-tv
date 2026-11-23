import AVFoundation
import SwiftUI

@main
struct SpelunkrTVApp: App {
    @State private var store = BroadcastStore()
    @AppStorage("themeMode") private var themeID = Theme.modern.id
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Theme.registerFonts()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(\.appTheme, Theme.resolve(themeID))
                .environment(\.themeSelection, $themeID)
                .preferredColorScheme(Theme.resolve(themeID).preferredColorScheme)
                .onAppear {
                    if themeID == "classic" { themeID = Theme.cable.id }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        store.presence.connect()
                        if let id = store.tv.channel?.id {
                            store.presence.track(channelID: id)
                        }
                    case .background:
                        store.presence.disconnect()
                    default:
                        break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(BroadcastStore.self) private var store
    @State private var selectedChannel: ChannelInfo?
    @State private var isFullScreen = false
    @State private var playbackOrigin: GuidePlaybackOrigin?

    var body: some View {
        ZStack {
            if store.channels.isEmpty {
                switch store.status {
                case .failed(let message):
                    StaticView(caption: message)
                        .overlay(alignment: .bottom) {
                            if store.canRetryStartup {
                                Button("Retry") { Task { await store.refresh(userInitiated: true) } }
                                    .padding(.bottom, 120)
                            }
                        }
                default:
                    StaticView(caption: "ADJUSTING THE ANTENNA…")
                }
            } else if isFullScreen {
                PlayerScreen(tv: store.tv) {
                    // Return to the guide with the same channel playing (no re-tune).
                    if let current = store.tv.channel {
                        selectedChannel = current
                    }
                    isFullScreen = false
                }
                .environment(\.colorScheme, .dark)
            } else {
                GuideHome(selectedChannel: $selectedChannel, playbackOrigin: $playbackOrigin) { channel in
                    guard let channel = store.channels.first(where: { $0.id == channel.id }), channel.isWatchable else { return }
                    selectedChannel = channel
                    if store.tv.channel?.id != channel.id {
                        store.tv.tune(channel)
                    }
                    store.presence.track(channelID: channel.id)
                    isFullScreen = true
                }
            }
        }
        .ignoresSafeArea()
        .task { store.start() }
    }
}
