import Foundation
import os

/// Timing log for tuning a channel. In Xcode's console, filter on category "tune"
/// (subsystem net.zerph.spelunkrtv). Every tune line looks like "[08 +1234ms] message".
/// The same steps are also emitted as signposts, so Instruments' os_signpost track shows them.
enum TuneLog {
    nonisolated static let logger = Logger(subsystem: "net.zerph.spelunkrtv", category: "tune")
    nonisolated static let signposter = OSSignposter(subsystem: "net.zerph.spelunkrtv", category: "tune")

    nonisolated static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    nonisolated static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    /// "<item id>/<file>" of a download address, shortened for log lines.
    nonisolated static func short(_ url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3 else { return url.lastPathComponent }
        let file = parts.last ?? ""
        return "\(parts[1].prefix(28))/\(file.prefix(24))"
    }
}
