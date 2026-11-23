import Foundation
import SwiftUI

// MARK: - lineup.json

struct Lineup: Decodable {
    let engine: Int?
    let generatedAt: String?
    let audioBase: String?
    let channels: [ChannelInfo]
}

struct ChannelInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String?
    let color: String?
    let description: String?
    let family: String?
    let dial: Int?
    let comingSoon: Bool?
    let debugOnly: Bool?
    let audioOverlay: Bool?
    let versions: [VersionPointer]

    static func == (a: ChannelInfo, b: ChannelInfo) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var dialText: String { dial.map { String(format: "%02d", $0) } ?? "--" }
    var tint: Color { Color(hex: color) ?? Color(red: 0.42, green: 0.25, blue: 0.95) }
    var isWatchable: Bool { comingSoon != true }
}

/// One published version of a channel's schedule (from lineup.json).
struct VersionPointer: Codable, Hashable {
    let v: Int
    let manifest: String
    let details: String?
    let epochMs: Int64
    let effectiveAtMs: Int64?
    let startIndex: Int?
}

/// Just enough of a channel manifest to find its shared "platform" bumper file.
struct ManifestHead: Decodable {
    let platform: String?
}

// MARK: - What the schedule engine returns

struct OnAir: Decodable, Equatable {
    struct NextShow: Decodable, Equatable {
        let title: String
        let year: String?
        let startMs: Double
    }
    struct BumpAudio: Decodable, Equatable {
        let filename: String
        let title: String?
        let artist: String?
        let startOffset: Double?
    }

    /// "video", "ad", "bump-break" or "up-next"
    let type: String
    let key: String
    let offset: Double
    let remaining: Double
    let startMs: Double
    let endMs: Double
    let version: Int
    let seekBase: Double
    let next: NextShow?

    // video and ad
    let id: String?
    let file: String?
    let title: String?
    let year: String?
    let gainDb: Double?
    /// Level (0.05 to 0.3) for a tape's own sound when music is laid over it; nil on other channels.
    let ambient: Double?

    // bump-break and up-next
    let channelSlides: [String]?
    let platformSlides: [String]?
    let half: String?
    let audio: BumpAudio?

    /// True for anything that plays a tape from the Internet Archive.
    var isTape: Bool { type == "video" || type == "ad" }

    /// Where in the tape the broadcast is right now.
    func expectedPosition(atMs nowMs: Double) -> Double {
        seekBase + max(0, (nowMs - startMs) / 1000)
    }

    func secondsLeft(atMs nowMs: Double) -> Double { max(0, (endMs - nowMs) / 1000) }

    /// Commercials carry a gain trim in dB (always negative).
    var volume: Float {
        guard let g = gainDb, g < 0 else { return 1 }
        return Float(pow(10, g / 20))
    }

    var displayTitle: String {
        switch type {
        case "video": return title ?? "Untitled tape"
        case "ad": return "Commercial break"
        case "up-next": return "Up next"
        default: return "Station break"
        }
    }
}

/// The music laid over a silent tape on an "audio overlay" channel (such as VACATION SLIDES).
/// The same track plays at the same moment for every viewer; where it is in the track right now
/// is `position(atMs:)`.
struct OverlayCue: Decodable, Equatable {
    struct Track: Decodable, Equatable {
        let id: String
        let file: String?
        let title: String?
        let artist: String?
        let duration: Double?
        /// Full address of the file when the schedule names one; otherwise look it up by `id`.
        let url: String?
    }

    /// Schedule key of the tape this music belongs to.
    let key: String
    let startMs: Double
    let endMs: Double
    /// Volume (0 to 0.3) for the tape's own sound; 0 means it is muted under the music.
    let ambient: Double
    /// Which entry of the tape's playlist this is, and when it starts, in seconds from the tape's start.
    let index: Int
    let startAt: Double
    /// When the next track takes over, if this tape has another one.
    let nextAtMs: Double?
    /// nil when the channel has no music for this tape.
    let track: Track?
    /// Stand-ins, in order, if `track` won't play.
    let fallbacks: [Track]

    /// Seconds into the track at `nowMs`.
    func position(atMs nowMs: Double) -> Double {
        max(0, (nowMs - startMs) / 1000 - startAt)
    }
}

struct GuideEntry: Decodable, Hashable {
    let title: String
    let year: String?
    let startMs: Double
    let endMs: Double
}

// MARK: - Helpers

extension Date {
    static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }
    init(ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
}

extension Color {
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
    static let spelunkrPurple = Color(red: 0x1C / 255, green: 0x0A / 255, blue: 0x57 / 255)
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func formatClock(_ ms: Double) -> String {
    Date(ms: ms).formatted(date: .omitted, time: .shortened)
}
