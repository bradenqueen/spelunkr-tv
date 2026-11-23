import AVFoundation
import AVKit
import UIKit

/// Frame-rate and dynamic-range matching for the Apple TV "Match Content" settings.
/// AVPlayerViewController does this by itself; with a bare AVPlayerLayer the app has to hand the
/// TV the tape's display criteria. Note that some TVs blank briefly while the display switches
/// modes, the same as they do in Apple's own apps.
@MainActor
enum DisplayMatching {
    /// What a tape asks for. Equal targets are never applied twice, so a run of 29.97 fps tapes
    /// and commercials causes no repeated mode switches.
    struct Target {
        let refreshRate: Float
        let format: CMFormatDescription

        func isSame(as other: Target) -> Bool {
            refreshRate == other.refreshRate && CFEqual(format, other.format)
        }
    }

    private static var applied: Target?

    /// The key window's display manager (the app is pure SwiftUI, so find the window through its scene).
    private static var displayManager: AVDisplayManager? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.keyWindow ?? scene?.windows.first,
              // AVKit adds avDisplayManager to UIWindow, but it isn't there everywhere (the
              // Simulator, for one), and calling a missing method crashes. Skip matching instead.
              window.responds(to: NSSelectorFromString("avDisplayManager")) else { return nil }
        return window.avDisplayManager
    }

    /// True when the viewer has turned on Match Frame Rate or Match Dynamic Range in Settings.
    static var isEnabled: Bool { displayManager?.isDisplayCriteriaMatchingEnabled ?? false }

    /// Reads the video track's frame rate and format. Runs off the main actor; nil if there is nothing usable.
    nonisolated static func target(for asset: AVAsset) async -> Target? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.nominalFrameRate),
              let format = try? await track.load(.formatDescriptions).first,
              rate > 0 else { return nil }
        return Target(refreshRate: rate, format: format)
    }

    /// Asks the TV to match `target`, unless it already has been asked for exactly that.
    static func apply(_ target: Target) {
        guard let manager = displayManager, manager.isDisplayCriteriaMatchingEnabled else { return }
        if let applied, applied.isSame(as: target) { return }
        applied = target
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: target.refreshRate,
                                                             formatDescription: target.format)
    }

    /// Hands the display back to the system (leaving the player).
    static func reset() {
        guard applied != nil else { return }
        applied = nil
        displayManager?.preferredDisplayCriteria = nil
    }
}
