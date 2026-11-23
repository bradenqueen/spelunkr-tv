#if DEBUG
import Foundation
import OSLog
import SwiftUI
import UIKit

struct StreamingHandoffProbe: View {
    enum Request {
        case link(URL)
        case invalid
    }

    static let launchRequest: Request? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--probe-streaming-link") else { return nil }
        let linkIndex = arguments.index(after: flagIndex)
        guard linkIndex < arguments.endIndex,
              let url = URL(string: arguments[linkIndex], encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(),
              scheme != "http",
              scheme != "file" else { return .invalid }
        if scheme == "https", url.host == nil { return .invalid }
        return .link(url)
    }()

    private static let logger = Logger(subsystem: "net.zerph.spelunkrtv", category: "streaming-handoff")

    let request: Request
    @State private var isOpening = false
    @State private var result: String?

    var body: some View {
        VStack(spacing: 28) {
            Text("Streaming handoff test")
                .font(.title)

            switch request {
            case .link(let url):
                Button("Open link") { open(url) }
                    .disabled(isOpening)
                Text(result ?? "Check which app and title open on this Apple TV.")
            case .invalid:
                Text("Add an HTTPS link or a provider-supplied app link after --probe-streaming-link in the Xcode Run arguments.")
            }
        }
        .multilineTextAlignment(.center)
        .padding(80)
    }

    private func open(_ url: URL) {
        let options: [UIApplication.OpenExternalURLOptionsKey: Any] =
            url.scheme?.lowercased() == "https" ? [.universalLinksOnly: true] : [:]

        isOpening = true
        result = "Requesting handoff…"
        Self.logger.notice("Requesting streaming handoff")
        UIApplication.shared.open(url, options: options) { accepted in
            isOpening = false
            if accepted {
                result = "Apple TV accepted the link. Verify the title in the provider app."
                Self.logger.notice("Apple TV accepted the streaming link")
            } else {
                result = "Apple TV could not open the link."
                Self.logger.notice("Apple TV could not open the streaming link")
            }
        }
    }
}
#endif
