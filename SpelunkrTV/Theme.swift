import CoreGraphics
import CoreText
import SwiftUI

/// WeatherStar 4000 visual system matched to spelunkr.tv's `theme-8s` palette, fonts, and borders.
enum Theme {
    // MARK: - Colors

    static let brandPurple = Color(red: 0x1C / 255, green: 0x0A / 255, blue: 0x57 / 255) // #1C0A57
    static let headerPurple = Color(red: 0x20 / 255, green: 0x00 / 255, blue: 0x57 / 255) // #200057
    static let deepNavy = Color(red: 0x00 / 255, green: 0x10 / 255, blue: 0x40 / 255) // #001040
    static let gridMidBlue = Color(red: 0x10 / 255, green: 0x20 / 255, blue: 0x80 / 255) // #102080
    static let panelBox = Color(red: 0x21 / 255, green: 0x28 / 255, blue: 0x5A / 255) // #21285A
    static let gridLine = Color(red: 0x00 / 255, green: 0x0A / 255, blue: 0x30 / 255) // #000A30

    static let yellow = Color(red: 1.0, green: 1.0, blue: 0.0) // #FFFF00
    static let yellowDim = Color(red: 0xD9 / 255, green: 0xB4 / 255, blue: 0x00 / 255) // #D9B400
    static let cyan = Color(red: 0x8F / 255, green: 0xFD / 255, blue: 0xFA / 255) // #8FFDFA
    static let softText = Color(red: 0xE6 / 255, green: 0xE8 / 255, blue: 1.0) // #E6E8FF
    static let blueMuted = Color(red: 0xA8 / 255, green: 0xA8 / 255, blue: 1.0) // #A8A8FF
    static let borderLight = Color(red: 0x85 / 255, green: 0x7B / 255, blue: 0xBE / 255) // #857BBE
    static let ringOuter = Color(red: 0x26 / 255, green: 0x52 / 255, blue: 0xB2 / 255) // #2652B2
    static let ringInner = Color(red: 0x23 / 255, green: 0x2C / 255, blue: 0x64 / 255) // #232C64
    static let liveRed = Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x4E / 255)

    // MARK: - Gradients

    static let screenBackground = LinearGradient(
        colors: [brandPurple, Color(red: 0x0B / 255, green: 0x10 / 255, blue: 0x45 / 255), deepNavy],
        startPoint: .top,
        endPoint: .bottom
    )

    static let panelGradient = LinearGradient(
        colors: [Color(red: 0x27 / 255, green: 0x2F / 255, blue: 0x6A / 255), Color(red: 0x16 / 255, green: 0x1C / 255, blue: 0x48 / 255)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let watchOrangeGradient = LinearGradient(
        colors: [
            Color(red: 0xD2 / 255, green: 0x66 / 255, blue: 0x06 / 255),
            Color(red: 0x9F / 255, green: 0x4A / 255, blue: 0x14 / 255),
            Color(red: 0x58 / 255, green: 0x26 / 255, blue: 0x3A / 255),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let focusRowGradient = LinearGradient(
        colors: [
            Color(red: 0xC8 / 255, green: 0x60 / 255, blue: 0x06 / 255),
            Color(red: 0x92 / 255, green: 0x44 / 255, blue: 0x1A / 255),
            Color(red: 0x52 / 255, green: 0x24 / 255, blue: 0x3C / 255),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let viewChannelBlueGradient = LinearGradient(
        colors: [
            Color(red: 0x5A / 255, green: 0x55 / 255, blue: 0xC8 / 255),
            Color(red: 0x2A / 255, green: 0x26 / 255, blue: 0xC8 / 255),
            Color(red: 0x02 / 255, green: 0x02 / 255, blue: 0xC8 / 255),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let progressFill = LinearGradient(
        colors: [yellow, yellowDim],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Time formatting (always 12-hour AM/PM like spelunkr.tv)

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    static func formatTime12(_ ms: Double) -> String {
        clockFormatter.string(from: Date(ms: ms))
    }

    // MARK: - Star4000 / Star3000 Fonts

    enum FontFace: String, CaseIterable {
        case regular = "star4000"
        case large = "star4000-large"
        case extended = "star4000-extended"
        case compressed = "star4000-large-compressed"
        case star3000 = "star3000"
        case star3000Heavy = "star3000-heavy"

        var fallbackWeight: Font.Weight {
            switch self {
            case .compressed, .extended, .star3000Heavy: return .heavy
            case .large, .star3000: return .bold
            case .regular: return .medium
            }
        }
    }

    private static var registeredPostScriptNames: [FontFace: String] = [:]
    private static var didRegisterFonts = false

    /// Registers any Star4000/Star3000 `.ttf` files bundled under `Fonts/` (or root bundle).
    /// Safe to call even if fonts were not downloaded: falls back to system monospaced fonts.
    static func registerFonts() {
        guard !didRegisterFonts else { return }
        didRegisterFonts = true

        var urls: [URL] = []
        if let sub = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
            urls.append(contentsOf: sub)
        }
        if let root = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
            urls.append(contentsOf: root)
        }

        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            guard let face = FontFace(rawValue: base) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let provider = CGDataProvider(url: url as CFURL),
               let cgFont = CGFont(provider),
               let psName = cgFont.postScriptName as String? {
                registeredPostScriptNames[face] = psName
            }
        }
    }

    static func font(_ face: FontFace, size: CGFloat) -> Font {
        if let psName = registeredPostScriptNames[face] {
            return .custom(psName, size: size)
        }
        return .system(size: size, weight: face.fallbackWeight, design: .monospaced)
    }

    // Named semantic styles
    static func heading(_ size: CGFloat = 34) -> Font { font(.compressed, size: size) }
    static func channelName(_ size: CGFloat = 28) -> Font { font(.extended, size: size) }
    static func dialNumber(_ size: CGFloat = 34) -> Font { font(.compressed, size: size) }
    static func body(_ size: CGFloat = 22) -> Font { font(.regular, size: size) }
    static func label(_ size: CGFloat = 18) -> Font { font(.star3000, size: size) }
    static func button(_ size: CGFloat = 22) -> Font { font(.star3000Heavy, size: size) }
    static func gridText(_ size: CGFloat = 20) -> Font { font(.large, size: size) }
}

// MARK: - Custom tvOS WeatherStar Button Styles (no white pill focus halo)

struct SpelunkrActionButtonStyle: ButtonStyle {
    let background: AnyShapeStyle
    var restingBorder: Color = Theme.borderLight
    var horizontalPadding: CGFloat = 24
    var verticalPadding: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        SpelunkrActionButtonBody(
            configuration: configuration,
            background: background,
            restingBorder: restingBorder,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }
}

private struct SpelunkrActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let background: AnyShapeStyle
    let restingBorder: Color
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            // ignoresSafeAreaEdges: [] keeps the fill inside the button (the default lets a
            // ShapeStyle background bleed into the safe area, which showed as a stray block).
            .background(background, ignoresSafeAreaEdges: [])
            .overlay(
                Rectangle()
                    .strokeBorder(isFocused ? Theme.yellow : restingBorder, lineWidth: isFocused ? 4 : 2)
            )
            .brightness(isFocused ? 0.12 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.04 : 1.0))
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .focusEffectDisabled()
    }
}

struct SpelunkrPlainFocusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .focusEffectDisabled()
    }
}

// MARK: - Reusable WeatherStar 4000 Components

struct SpelunkrPanel<Content: View>: View {
    var borderColor: Color = Theme.ringOuter
    var cornerRadius: CGFloat = 2
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(Theme.panelGradient, ignoresSafeAreaEdges: [])
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor, lineWidth: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 1))
                    .strokeBorder(Theme.ringInner, lineWidth: 2)
                    .padding(4)
            )
    }
}

struct SpelunkrProgressBar: View {
    let progress: Double
    let elapsedText: String
    let remainingText: String

    /// Elapsed time, bar and remaining time on one row, like the web info panel.
    var body: some View {
        HStack(spacing: 14) {
            Text(elapsedText)
                .font(Theme.label(24))
                .foregroundStyle(Theme.softText)
                .lineLimit(1)
                .fixedSize()

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.deepNavy)
                    Rectangle()
                        .fill(Theme.progressFill)
                        .frame(width: geo.size.width * min(1, max(0, progress)))
                }
                .overlay(Rectangle().stroke(Theme.borderLight.opacity(0.75), lineWidth: 1))
            }
            .frame(height: 14)

            Text(remainingText)
                .font(Theme.label(24))
                .foregroundStyle(Theme.softText)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct ViewerBadge: View {
    let count: Int
    var suffix: String? = nil
    var fontSize: CGFloat = 23
    var color: Color = Theme.softText

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.fill")
                .font(.system(size: fontSize * 0.85, weight: .bold))
            Text(suffix.map { "\(PresenceClient.formatCount(count)) \($0)" } ?? PresenceClient.formatCount(count))
                .font(Theme.label(fontSize))
        }
        .foregroundStyle(color)
    }
}

struct FamilyBadge: View {
    let family: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.inset.filled")
                .font(.system(size: 17, weight: .bold))
            Text(family.replacingOccurrences(of: "-", with: " ").uppercased())
                .font(Theme.label(21))
        }
        .foregroundStyle(Theme.cyan)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.deepNavy.opacity(0.85))
        .overlay(Rectangle().stroke(Theme.cyan.opacity(0.55), lineWidth: 1))
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.liveRed)
                .frame(width: 12, height: 12)
            Text("LIVE")
                .font(Theme.label(21))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.deepNavy.opacity(0.9))
        .overlay(Rectangle().stroke(Theme.liveRed.opacity(0.8), lineWidth: 1))
    }
}

extension View {
    /// Crisp WeatherStar-style drop shadow for legibility on dark blue/purple panels.
    func wsShadow() -> some View {
        shadow(color: .black.opacity(0.9), radius: 0, x: 2, y: 2)
    }
}
