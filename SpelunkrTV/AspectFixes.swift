import CoreGraphics
import Foundation

// MARK: - What spelunkr.tv knows about how individual tapes should be shown
//
// The site loads three small maps, keyed "<archive id>/<file name>" (the same key for shows and
// for commercial tapes, because it derives the key from the address of the file being played):
//
//   /stretch.json  number 1...2.5   The tape is squeezed (anamorphic, or 4:3 pictures stored in a
//                                   16:9 frame, or the reverse). The value is the aspect ratio the
//                                   picture should really have; the site stretches the video to
//                                   that shape (object-fit: fill) inside a box of that ratio.
//   /zoom.json     [x, y, w, h]     The picture sits inside a black border (letterbox, pillarbox or
//                                   both). The four numbers (0...1) are where the real picture is in
//                                   the frame; the site scales up to fill the screen (at most 1.7x,
//                                   and only if that is at least 1.03x) and clips the border off.
//   /crop43.json   number           How much of a 4:3 picture a 16:9 frame holds. The site only uses
//                                   this in its optional CRT mode (a 4:3 screen, object-fit: cover
//                                   and scale(min(1.08, 0.75 / value))). It is not part of the normal
//                                   16:9 picture, so the Apple TV app loads it but does not apply it.

/// The picture changes to make for one tape. `.none` means show it as it is.
struct PictureCorrection: Equatable {
    /// Aspect ratio to stretch the picture to (1...2.5), or nil.
    var stretch: Double?
    /// Where the real picture is inside the frame, as fractions of the frame (x, y, width, height), or nil.
    var zoom: CGRect?

    static let none = PictureCorrection()
    var isNone: Bool { stretch == nil && zoom == nil }
}

/// Downloads the three maps and answers "how should this tape be shown?".
@MainActor
final class AspectFixes {
    private(set) var stretch: [String: Double] = [:]
    private(set) var zoom: [String: [Double]] = [:]
    private(set) var crop43: [String: Double] = [:]

    private var haveStretch = false
    private var haveZoom = false
    private var haveCrop43 = false
    private var loading = false

    nonisolated static let base = URL(string: "https://spelunkr.tv/")!

    /// Fetches whatever is still missing. Safe to call again; it retries a few times if the network is down.
    func load() async {
        guard !loading, !(haveStretch && haveZoom && haveCrop43) else { return }
        loading = true
        defer { loading = false }
        for attempt in 0..<5 {
            if !haveStretch, let m = await Self.fetchMap("stretch.json", as: [String: Double].self) {
                stretch = m; haveStretch = true
            }
            if !haveZoom, let m = await Self.fetchMap("zoom.json", as: [String: [Double]].self) {
                zoom = m; haveZoom = true
            }
            if !haveCrop43, let m = await Self.fetchMap("crop43.json", as: [String: Double].self) {
                crop43 = m; haveCrop43 = true
            }
            if haveStretch && haveZoom && haveCrop43 { return }
            try? await Task.sleep(for: .seconds(15 * Double(attempt + 1)))
        }
    }

    nonisolated private static func fetchMap<T: Decodable>(_ name: String, as type: T.Type) async -> T? {
        guard let text = try? await BroadcastStore.fetchText(base.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    /// The corrections for the tape at `url` (an Internet Archive download address).
    func correction(for url: URL) -> PictureCorrection {
        guard let key = Self.key(for: url) else { return .none }
        return correction(forKey: key)
    }

    func correction(forKey key: String) -> PictureCorrection {
        PictureCorrection(stretch: stretch[key].flatMap(Self.validStretch),
                          zoom: zoom[key].flatMap(Self.validZoom))
    }

    /// Zoom factor the site's CRT mode would apply to this tape (1 = none). Not used on a 16:9 TV.
    func crop43Zoom(forKey key: String) -> Double {
        guard let v = crop43[key], v > 0, v < 0.75 else { return 1 }
        return min(1.08, (0.75 / v * 1000).rounded() / 1000)
    }

    // MARK: Keys

    /// The site's key for a media address: "<id>/<file>". Same rules as the site: after a
    /// "download" (or items / ia / node) path segment come the item id and the file name,
    /// otherwise it is the last two path segments. Segments are percent-decoded.
    nonisolated static func key(for url: URL) -> String? {
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        if let i = parts.firstIndex(where: { ["download", "items", "ia", "node"].contains($0) }), parts.count >= i + 3 {
            return "\(parts[i + 1])/\(parts[(i + 2)...].joined(separator: "/"))"
        }
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }

    /// The key for an item named in the schedule: archive id plus file name (what the URL would decode to).
    nonisolated static func key(id: String, file: String) -> String { "\(id)/\(file)" }

    // MARK: Validation (same limits as the site)

    nonisolated static func validStretch(_ v: Double) -> Double? {
        v.isFinite && v >= 1 && v <= 2.5 ? v : nil
    }

    nonisolated static func validZoom(_ a: [Double]) -> CGRect? {
        guard a.count == 4, a.allSatisfy(\.isFinite) else { return nil }
        let (x, y, w, h) = (a[0], a[1], a[2], a[3])
        if x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > 1.0005 || y + h > 1.0005 { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Turning a correction into a layer placement

/// Where to put the video layer inside its container so that it looks like the website.
struct PictureLayout: Equatable {
    /// Frame of the video layer inside the container.
    var frame: CGRect
    /// True: stretch the picture to fill `frame` (AVLayerVideoGravity.resize). False: letterbox as usual.
    var fill: Bool
    /// Transform to apply to the layer about its centre.
    var transform: CGAffineTransform
    /// Part of the layer to keep (in the layer's own coordinates, before the transform), or nil for all of it.
    var visible: CGRect?
}

enum PictureGeometry {
    /// Largest enlargement the site allows when zooming a bordered picture, and the smallest that is worth doing.
    static let maxZoom = 1.7
    static let minZoom = 1.03

    static func layout(container: CGSize, video: CGSize, correction: PictureCorrection) -> PictureLayout {
        let full = CGRect(origin: .zero, size: container)
        let plain = PictureLayout(frame: full, fill: false, transform: .identity, visible: nil)
        guard container.width > 0, container.height > 0 else { return plain }

        if let ratio = correction.stretch {
            // A box of the true shape, as large as fits and centred; the picture is stretched to it.
            let screen = Double(container.width / container.height)
            let wider = screen > ratio
            let widthPct = wider ? ratio / screen * 100 : 100
            let heightPct = wider ? 100 : screen / ratio * 100
            let box = CGRect(x: Double(container.width) * (100 - widthPct) / 200,
                             y: Double(container.height) * (100 - heightPct) / 200,
                             width: Double(container.width) * widthPct / 100,
                             height: Double(container.height) * heightPct / 100)
            return PictureLayout(frame: box, fill: true, transform: .identity, visible: nil)
        }

        if let rect = correction.zoom, let z = zoom(container: container, video: video, content: rect) {
            return PictureLayout(frame: full, fill: false, transform: z.transform, visible: z.visible)
        }
        return plain
    }

    /// Port of the site's zoom maths: scale the real picture up to fill the screen, centre it, and
    /// clip the border away. All lengths are in points.
    static func zoom(container: CGSize, video: CGSize, content n: CGRect) -> (transform: CGAffineTransform, visible: CGRect)? {
        let r = Double(container.width), s = Double(container.height)
        let vw = Double(video.width), vh = Double(video.height)
        guard r > 0, s > 0, vw > 0, vh > 0 else { return nil }
        let fit = min(r / vw, s / vh)
        let l = vw * fit, u = vh * fit                       // the picture as drawn, letterboxed
        let want = min(r / (Double(n.width) * l), s / (Double(n.height) * u))
        let scale = min(maxZoom, round(want, 4))
        guard scale >= minZoom else { return nil }
        let f = (Double(n.minX) + Double(n.width) / 2 - 0.5) * l   // centre of the real picture, from the middle
        let p = (Double(n.minY) + Double(n.height) / 2 - 0.5) * u
        let tx = round(-scale * f, 2), ty = round(-scale * p, 2)
        let m = r / 2 * (1 - 1 / scale), y = s / 2 * (1 - 1 / scale)
        let top = max(0, round(y + p, 2)), right = max(0, round(m - f, 2))
        let bottom = max(0, round(y - p, 2)), left = max(0, round(m + f, 2))
        // translate(tx, ty) scale(scale): scale first, then move.
        let transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        let visible = CGRect(x: left, y: top, width: r - left - right, height: s - top - bottom)
        guard visible.width > 0, visible.height > 0 else { return nil }
        return (transform, visible)
    }

    private static func round(_ v: Double, _ places: Int) -> Double {
        let k = pow(10.0, Double(places))
        return (v * k).rounded() / k
    }
}
