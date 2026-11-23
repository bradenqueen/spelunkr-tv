import AVFoundation
import SwiftUI

@main
struct SpelunkrTVApp: App {
    @State private var store = BroadcastStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Theme.registerFonts()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
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

    var body: some View {
        ZStack {
            if store.channels.isEmpty {
                switch store.status {
                case .failed(let message):
                    StaticView(caption: message)
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
            } else {
                GuideHome(selectedChannel: $selectedChannel) { channel in
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
