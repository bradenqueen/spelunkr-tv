import CoreGraphics
import CoreText
import SwiftUI

/// The appearance of the app's shared tvOS interface.
struct Theme: Identifiable {
    let id: String
    let name: String
    let summary: String

    let brandSurface: Color
    let gridHeaderFill: Color
    let baseSurface: Color
    let alternateRowFill: Color
    let raisedSurface: Color
    let gridLine: Color
    let accent: Color
    let secondaryAccent: Color
    let primaryText: Color
    let softText: Color
    let mutedText: Color
    let controlBorder: Color
    let panelBorder: Color
    let panelInnerBorder: Color
    let liveBadgeAccent: Color
    let liveIndicator: Color
    let liveProgramMarker: Color?
    let warningAccent: Color
    let focusBorder: Color
    let selectedBorder: Color

    let screenBackground: LinearGradient
    let panelFill: LinearGradient
    let primaryActionFill: LinearGradient
    let focusedFill: LinearGradient
    let secondaryActionFill: LinearGradient
    let progressFill: LinearGradient
    let selectedRowFill: AnyShapeStyle

    let panelCornerRadius: CGFloat
    let controlCornerRadius: CGFloat
    let cellCornerRadius: CGFloat
    let panelBorderWidth: CGFloat
    let panelInnerBorderWidth: CGFloat
    let playerBorderWidth: CGFloat
    let playerBannerCornerRadius: CGFloat
    let showsAnimatedStatic: Bool
    let statusCaptionFont: Font
    let statusCaptionBackground: Color
    let statusCaptionCornerRadius: CGFloat
    let bufferingBackground: Color
    let bufferingCornerRadius: CGFloat

    fileprivate let buttonFocusFill: Color?
    fileprivate let buttonFocusBrightness: Double
    fileprivate let buttonFocusScale: CGFloat
    fileprivate let buttonBorderWidth: CGFloat
    fileprivate let showsTextShadow: Bool
    private let typography: Typography

    private enum Typography {
        case weatherStar
        case system(headingDesign: Font.Design)
    }

    enum GuideLayout: String {
        case timeline, daylight, cinema, channelWall, scheduleDesk, largePrint, spotlight
    }

    enum PlayerPresentation {
        case infoBanner, cable, daylight, cinema, channelWall, scheduleDesk, largePrint, spotlight
    }

    var guideLayout: GuideLayout = .timeline
    var playerPresentation: PlayerPresentation = .infoBanner
    var preferredColorScheme: ColorScheme { guideLayout == .daylight ? .light : .dark }

    static let modern: Theme = {
        let brandSurface = rgb(0x211839)
        let baseSurface = rgb(0x0D1328)
        let raisedSurface = rgb(0x252442)
        let accent = rgb(0xDBC9FF)
        let amber = rgb(0xFFC878)
        let focusFill = vertical([rgb(0x504078), rgb(0x3B305F)])

        return Theme(
            id: "modern",
            name: "Modern",
            summary: "Deep navy, violet accents, and cleaner lettering.",
            brandSurface: brandSurface,
            gridHeaderFill: rgb(0x24213E),
            baseSurface: baseSurface,
            alternateRowFill: rgb(0x30345A),
            raisedSurface: raisedSurface,
            gridLine: rgb(0x333455),
            accent: accent,
            secondaryAccent: rgb(0xA1DCF0),
            primaryText: rgb(0xF8F5FF),
            softText: rgb(0xDED9EE),
            mutedText: rgb(0xC0BBD5),
            controlBorder: rgb(0x716395),
            panelBorder: rgb(0x4F466F),
            panelInnerBorder: .clear,
            liveBadgeAccent: rgb(0xFF677C),
            liveIndicator: amber,
            liveProgramMarker: amber,
            warningAccent: amber,
            focusBorder: rgb(0xF5EDFF),
            selectedBorder: rgb(0xA58CDD),
            screenBackground: vertical([brandSurface, rgb(0x161B34), baseSurface]),
            panelFill: vertical([rgb(0x292443), rgb(0x1B2039)]),
            primaryActionFill: vertical([rgb(0x6743A2), rgb(0x4E3383)]),
            focusedFill: focusFill,
            secondaryActionFill: vertical([rgb(0x413960), rgb(0x333250)]),
            progressFill: vertical([accent, rgb(0xAC8AF4)]),
            selectedRowFill: AnyShapeStyle(rgb(0x362952)),
            panelCornerRadius: 18,
            controlCornerRadius: 12,
            cellCornerRadius: 8,
            panelBorderWidth: 1,
            panelInnerBorderWidth: 0,
            playerBorderWidth: 1,
            playerBannerCornerRadius: 0,
            showsAnimatedStatic: false,
            statusCaptionFont: .system(size: 38, weight: .semibold),
            statusCaptionBackground: raisedSurface,
            statusCaptionCornerRadius: 18,
            bufferingBackground: raisedSurface,
            bufferingCornerRadius: 16,
            buttonFocusFill: rgb(0x514073),
            buttonFocusBrightness: 0,
            buttonFocusScale: 1.025,
            buttonBorderWidth: 1,
            showsTextShadow: false,
            typography: .system(headingDesign: .default)
        )
    }()

    static let neon: Theme = {
        let brandSurface = rgb(0x1C1927)
        let baseSurface = rgb(0x090A10)
        let raisedSurface = rgb(0x20212E)
        let mint = rgb(0x8FFFE1)
        let pink = rgb(0xFFACEF)
        let violet = rgb(0xAF9CFF)
        let lime = rgb(0xE0FA80)

        return Theme(
            id: "neon",
            name: "Neon",
            summary: "A floating player banner and graphite panels with mint, pink, and violet accents.",
            brandSurface: brandSurface,
            gridHeaderFill: rgb(0x1C1D27),
            baseSurface: baseSurface,
            alternateRowFill: rgb(0x2A2A37),
            raisedSurface: raisedSurface,
            gridLine: rgb(0x292B39),
            accent: mint,
            secondaryAccent: pink,
            primaryText: rgb(0xF8F8FC),
            softText: rgb(0xDFDEE9),
            mutedText: rgb(0xBCBCCD),
            controlBorder: rgb(0x66677C),
            panelBorder: rgb(0x414253),
            panelInnerBorder: .clear,
            liveBadgeAccent: rgb(0xFF809A),
            liveIndicator: lime,
            liveProgramMarker: lime,
            warningAccent: rgb(0xFFD28B),
            focusBorder: rgb(0xC9FFF0),
            selectedBorder: violet,
            screenBackground: LinearGradient(
                colors: [brandSurface, rgb(0x131622), baseSurface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            panelFill: vertical([rgb(0x252631), rgb(0x181924)]),
            primaryActionFill: vertical([rgb(0x23483F), rgb(0x18352F)]),
            focusedFill: LinearGradient(
                colors: [rgb(0x2A4845), rgb(0x343249)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            secondaryActionFill: vertical([rgb(0x303144), raisedSurface]),
            progressFill: LinearGradient(colors: [mint, violet, pink], startPoint: .leading, endPoint: .trailing),
            selectedRowFill: AnyShapeStyle(rgb(0x2D2743)),
            panelCornerRadius: 30,
            controlCornerRadius: 20,
            cellCornerRadius: 12,
            panelBorderWidth: 1,
            panelInnerBorderWidth: 0,
            playerBorderWidth: 1,
            playerBannerCornerRadius: 32,
            showsAnimatedStatic: false,
            statusCaptionFont: .system(size: 38, weight: .semibold, design: .rounded),
            statusCaptionBackground: raisedSurface,
            statusCaptionCornerRadius: 26,
            bufferingBackground: raisedSurface.opacity(0.94),
            bufferingCornerRadius: 24,
            buttonFocusFill: rgb(0x2B453F),
            buttonFocusBrightness: 0,
            buttonFocusScale: 1.035,
            buttonBorderWidth: 1,
            showsTextShadow: false,
            typography: .system(headingDesign: .rounded)
        )
    }()

    static let cable: Theme = {
        let brandSurface = rgb(0x151746)
        let baseSurface = rgb(0x080A20)
        let accent = rgb(0xFFDA59)
        let focusFill = vertical([rgb(0x464030), rgb(0x343044), rgb(0x222651)])

        return Theme(
            id: "cable",
            name: "Cable Guide",
            summary: "Midnight blue, a gold tuning indicator, and retro cable lettering.",
            brandSurface: brandSurface,
            gridHeaderFill: rgb(0x131635),
            baseSurface: baseSurface,
            alternateRowFill: rgb(0x22295F),
            raisedSurface: rgb(0x1C2152),
            gridLine: rgb(0x10132B),
            accent: accent,
            secondaryAccent: rgb(0x9AC9FF),
            primaryText: .white,
            softText: rgb(0xE6E8FF),
            mutedText: rgb(0xB2B8D8),
            controlBorder: rgb(0x626C9C),
            panelBorder: rgb(0x414C80),
            panelInnerBorder: rgb(0x232A53),
            liveBadgeAccent: rgb(0xFF3B4E),
            liveIndicator: accent,
            liveProgramMarker: nil,
            warningAccent: .orange,
            focusBorder: accent,
            selectedBorder: accent,
            screenBackground: vertical([brandSurface, rgb(0x101234), baseSurface]),
            panelFill: vertical([rgb(0x252B68), rgb(0x171C48)]),
            primaryActionFill: vertical([rgb(0x4F4225), rgb(0x403721), rgb(0x292640)]),
            focusedFill: focusFill,
            secondaryActionFill: vertical([rgb(0x30376B), rgb(0x272D61), rgb(0x1C2252)]),
            progressFill: vertical([accent, rgb(0xD9B400)]),
            selectedRowFill: AnyShapeStyle(focusFill),
            panelCornerRadius: 8,
            controlCornerRadius: 6,
            cellCornerRadius: 5,
            panelBorderWidth: 1,
            panelInnerBorderWidth: 0,
            playerBorderWidth: 1,
            playerBannerCornerRadius: 0,
            showsAnimatedStatic: true,
            statusCaptionFont: .system(size: 40, weight: .heavy, design: .monospaced),
            statusCaptionBackground: .black.opacity(0.7),
            statusCaptionCornerRadius: 10,
            bufferingBackground: .black.opacity(0.7),
            bufferingCornerRadius: 8,
            buttonFocusFill: nil,
            buttonFocusBrightness: 0.12,
            buttonFocusScale: 1.015,
            buttonBorderWidth: 2,
            showsTextShadow: false,
            typography: .weatherStar,
            playerPresentation: .cable
        )
    }()

    var usesCableLayout: Bool { id == Self.cable.id }

    private static func edition(
        _ layout: GuideLayout, _ player: PlayerPresentation, name: String, summary: String,
        canvas: UInt32, panel: UInt32, raised: UInt32, ink: UInt32, secondaryInk: UInt32,
        accent: UInt32, secondary: UInt32, focus: UInt32, border: UInt32,
        radius: CGFloat, heading: Font.Design = .default
    ) -> Theme {
        let base = rgb(canvas), surface = rgb(panel), upper = rgb(raised)
        let text = rgb(ink), subdued = rgb(secondaryInk), highlight = rgb(accent)
        let detail = rgb(secondary), active = rgb(focus), line = rgb(border)
        let focused = vertical([active, active])
        return Theme(
            id: layout.rawValue, name: name, summary: summary,
            brandSurface: surface, gridHeaderFill: upper, baseSurface: base,
            alternateRowFill: surface, raisedSurface: upper, gridLine: line,
            accent: highlight, secondaryAccent: detail, primaryText: text,
            softText: subdued, mutedText: subdued, controlBorder: line, panelBorder: line,
            panelInnerBorder: .clear, liveBadgeAccent: detail, liveIndicator: highlight,
            liveProgramMarker: highlight, warningAccent: detail, focusBorder: highlight,
            selectedBorder: detail, screenBackground: vertical([base, surface]),
            panelFill: vertical([surface, surface]), primaryActionFill: focused,
            focusedFill: focused, secondaryActionFill: vertical([upper, upper]),
            progressFill: vertical([highlight, detail]), selectedRowFill: AnyShapeStyle(upper),
            panelCornerRadius: radius, controlCornerRadius: radius, cellCornerRadius: radius / 2,
            panelBorderWidth: 1, panelInnerBorderWidth: 0, playerBorderWidth: 1,
            playerBannerCornerRadius: radius, showsAnimatedStatic: false,
            statusCaptionFont: .system(size: 38, weight: .semibold),
            statusCaptionBackground: surface, statusCaptionCornerRadius: radius,
            bufferingBackground: surface, bufferingCornerRadius: radius,
            buttonFocusFill: active, buttonFocusBrightness: 0, buttonFocusScale: 1.015,
            buttonBorderWidth: 2, showsTextShadow: false,
            typography: .system(headingDesign: heading), guideLayout: layout, playerPresentation: player
        )
    }

    static let daylight = edition(
        .daylight, .daylight, name: "Daylight", summary: "A light guide with a preview and an airy channel list.",
        canvas: 0xF8F6EF, panel: 0xF1EFE6, raised: 0xE4E7DB, ink: 0x17281F,
        secondaryInk: 0x46544A, accent: 0x185A44, secondary: 0x824215,
        focus: 0xCDDFD2, border: 0x84968A, radius: 10
    )
    static let cinema = edition(
        .cinema, .cinema, name: "Cinema", summary: "A large live preview beside a vertical list of channels.",
        canvas: 0x110D0D, panel: 0x221919, raised: 0x342627, ink: 0xFFF4E9,
        secondaryInk: 0xD7C5BC, accent: 0xF5C981, secondary: 0xF9A79A,
        focus: 0x584031, border: 0x76605B, radius: 4, heading: .serif
    )
    static let channelWall = edition(
        .channelWall, .channelWall, name: "Channel Wall", summary: "Browse stations on a wall of channel tiles.",
        canvas: 0x091721, panel: 0x122733, raised: 0x183746, ink: 0xF2FAFC,
        secondaryInk: 0xB8D7DE, accent: 0x76E3D0, secondary: 0xF5CD78,
        focus: 0x23505B, border: 0x537884, radius: 14, heading: .rounded
    )
    static let scheduleDesk = edition(
        .scheduleDesk, .scheduleDesk, name: "Schedule Desk", summary: "An agenda of programs alongside the channel roster.",
        canvas: 0x111B19, panel: 0x1A2824, raised: 0x283A32, ink: 0xF5F2DB,
        secondaryInk: 0xC8D3BE, accent: 0xDCE99A, secondary: 0xA4DCCC,
        focus: 0x40503B, border: 0x647969, radius: 2, heading: .monospaced
    )
    static let largePrint = edition(
        .largePrint, .largePrint, name: "Large Print", summary: "Oversized channel rows and high-contrast controls.",
        canvas: 0x080808, panel: 0x101010, raised: 0x272727, ink: 0xFFFFFF,
        secondaryInk: 0xF5F5F5, accent: 0xFFDF55, secondary: 0xA4ECFF,
        focus: 0x383838, border: 0xAFAFAF, radius: 8
    )
    static let spotlight = edition(
        .spotlight, .spotlight, name: "Spotlight", summary: "Browse what is on now or coming up in two rows of program cards.",
        canvas: 0x191222, panel: 0x291D36, raised: 0x3D2B48, ink: 0xFFF2FA,
        secondaryInk: 0xE4CDE1, accent: 0xFFC2DC, secondary: 0xCCD2FF,
        focus: 0x583B55, border: 0x886981, radius: 18, heading: .serif
    )

    static let catalog: [Theme] = [
        .modern, .neon, .cable, .daylight, .cinema, .channelWall, .scheduleDesk, .largePrint, .spotlight
    ]

    static func resolve(_ id: String) -> Theme {
        if id == "classic" { return cable }
        return catalog.first { $0.id == id } ?? modern
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    private static func vertical(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

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

    private enum FontFace: String, CaseIterable {
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

    private static func weatherStarFont(_ face: FontFace, size: CGFloat) -> Font {
        if let psName = registeredPostScriptNames[face] {
            return .custom(psName, size: size)
        }
        return .system(size: size, weight: face.fallbackWeight, design: .monospaced)
    }

    func heading(_ size: CGFloat = 34) -> Font {
        switch typography {
        case .weatherStar: return Self.weatherStarFont(.compressed, size: size)
        case .system(let design): return .system(size: size, weight: .bold, design: design)
        }
    }

    func channelName(_ size: CGFloat = 28) -> Font {
        font(.extended, size: size, weight: .semibold)
    }

    func dialNumber(_ size: CGFloat = 34) -> Font {
        font(.compressed, size: size, weight: .bold, design: .monospaced)
    }

    func body(_ size: CGFloat = 22) -> Font {
        font(.regular, size: size, weight: .regular)
    }

    func label(_ size: CGFloat = 18) -> Font {
        font(.star3000, size: size, weight: .medium)
    }

    func time(_ size: CGFloat) -> Font {
        font(.star3000, size: size, weight: .medium, design: .monospaced)
    }

    func button(_ size: CGFloat = 22) -> Font {
        font(.star3000Heavy, size: size, weight: .semibold)
    }

    func gridText(_ size: CGFloat = 20) -> Font {
        font(.large, size: size, weight: .semibold)
    }

    private func font(
        _ face: FontFace,
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design = .default
    ) -> Font {
        switch typography {
        case .weatherStar: return Self.weatherStarFont(face, size: size)
        case .system: return .system(size: size, weight: weight, design: design)
        }
    }
}

private enum AppThemeKey: EnvironmentKey {
    static let defaultValue = Theme.modern
}

private struct CableScanlines: ViewModifier {
    @Environment(\.appTheme) private var theme
    @AppStorage("cableScanlines") private var enabled = true

    func body(content: Content) -> some View {
        content.overlay {
            if theme.usesCableLayout, enabled {
                Canvas { context, size in
                    var lines = Path()
                    for y in stride(from: CGFloat(1), to: size.height, by: 4) {
                        lines.move(to: CGPoint(x: 0, y: y))
                        lines.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(lines, with: .color(.black.opacity(0.22)), lineWidth: 1)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func cableScanlines() -> some View {
        modifier(CableScanlines())
    }
}

extension EnvironmentValues {
    var appTheme: Theme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - Shared tvOS Button Styles

struct SpelunkrActionButtonStyle: ButtonStyle {
    let background: AnyShapeStyle
    var restingBorder: Color? = nil
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
    let restingBorder: Color?
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlCornerRadius)
        let fill = isFocused ? (theme.buttonFocusFill.map { AnyShapeStyle($0) } ?? background) : background

        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(fill, in: shape)
            .overlay(
                shape.strokeBorder(
                    isFocused ? theme.focusBorder : (restingBorder ?? theme.controlBorder),
                    lineWidth: isFocused ? (theme.guideLayout == .largePrint ? 6 : 4) : theme.buttonBorderWidth
                )
            )
            .brightness(isFocused ? theme.buttonFocusBrightness : 0)
            .scaleEffect(reduceMotion ? 1 : scale)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isFocused)
            .focusEffectDisabled()
    }

    private var scale: CGFloat {
        if configuration.isPressed { return 0.96 }
        return isFocused ? theme.buttonFocusScale : 1
    }
}

struct SpelunkrPlainFocusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .focusEffectDisabled()
    }
}

// MARK: - Shared Components

struct SpelunkrPanel<Content: View>: View {
    var borderColor: Color? = nil
    var cornerRadius: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.appTheme) private var theme

    var body: some View {
        let radius = cornerRadius ?? theme.panelCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius)

        content()
            .background(theme.panelFill, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(borderColor ?? theme.panelBorder, lineWidth: theme.panelBorderWidth))
            .overlay {
                if theme.panelInnerBorderWidth > 0 {
                    RoundedRectangle(cornerRadius: max(0, radius - 1))
                        .strokeBorder(theme.panelInnerBorder, lineWidth: theme.panelInnerBorderWidth)
                        .padding(theme.panelBorderWidth)
                }
            }
    }
}

struct SpelunkrProgressBar: View {
    let progress: Double
    let elapsedText: String
    let remainingText: String
    @Environment(\.appTheme) private var theme

    /// Elapsed time, bar, and remaining time on one row.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(7, theme.controlCornerRadius))

        HStack(spacing: 14) {
            Text(elapsedText)
                .font(theme.time(24))
                .foregroundStyle(theme.softText)
                .lineLimit(1)
                .fixedSize()

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(theme.baseSurface)
                    Rectangle()
                        .fill(theme.progressFill)
                        .frame(width: geo.size.width * min(1, max(0, progress)))
                }
                .clipShape(shape)
                .overlay(shape.stroke(theme.controlBorder.opacity(0.75), lineWidth: 1))
            }
            .frame(height: 14)

            Text(remainingText)
                .font(theme.time(24))
                .foregroundStyle(theme.softText)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct ViewerBadge: View {
    let count: Int
    var suffix: String? = nil
    var fontSize: CGFloat = 23
    var color: Color? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.fill")
                .font(.system(size: fontSize * 0.85, weight: .bold))
            Text(suffix.map { "\(PresenceClient.formatCount(count)) \($0)" } ?? PresenceClient.formatCount(count))
                .font(theme.label(fontSize))
        }
        .foregroundStyle(color ?? theme.softText)
    }
}

struct FamilyBadge: View {
    let family: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlCornerRadius)

        HStack(spacing: 5) {
            Image(systemName: "square.inset.filled")
                .font(.system(size: 17, weight: .bold))
            Text(family.replacingOccurrences(of: "-", with: " ").uppercased())
                .font(theme.label(21))
        }
        .foregroundStyle(theme.secondaryAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.baseSurface.opacity(0.85), in: shape)
        .overlay(shape.stroke(theme.secondaryAccent.opacity(0.55), lineWidth: 1))
    }
}

struct LiveBadge: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlCornerRadius)

        HStack(spacing: 6) {
            Circle()
                .fill(theme.liveBadgeAccent)
                .frame(width: 12, height: 12)
            Text("LIVE")
                .font(theme.label(21))
                .foregroundStyle(theme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.baseSurface.opacity(0.9), in: shape)
        .overlay(shape.stroke(theme.liveBadgeAccent.opacity(0.8), lineWidth: 1))
    }
}

extension View {
    func wsShadow() -> some View {
        modifier(ThemeTextShadow())
    }
}

private struct ThemeTextShadow: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.shadow(color: theme.showsTextShadow ? .black.opacity(0.9) : .clear, radius: 0, x: 2, y: 2)
    }
}
