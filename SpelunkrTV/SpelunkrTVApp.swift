import AVFoundation
import SwiftUI

@main
struct SpelunkrTVApp: App {
    @State private var store = BroadcastStore()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(BroadcastStore.self) private var store
    @State private var watching: ChannelInfo?
    @State private var lastChannelID: String?

    var body: some View {
        ZStack {
            if store.channels.isEmpty {
                switch store.status {
                case .failed(let message):
                    StaticView(caption: message)
                default:
                    StaticView(caption: "ADJUSTING THE ANTENNA…")
                }
            } else if watching != nil {
                PlayerScreen(tv: store.tv) {
                    lastChannelID = store.tv.channel?.id ?? watching?.id
                    store.tv.stop()
                    watching = nil
                }
            } else {
                GuideView(initialFocus: lastChannelID) { channel in
                    watching = channel
                    store.tv.tune(channel)
                }
            }
        }
        .ignoresSafeArea()
        .task { store.start() }
    }
}
