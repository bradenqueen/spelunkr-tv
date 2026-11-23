import SwiftUI

private struct ThemeSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<String>? = nil
}

extension EnvironmentValues {
    var themeSelection: Binding<String>? {
        get { self[ThemeSelectionKey.self] }
        set { self[ThemeSelectionKey.self] = newValue }
    }
}

struct ThemePicker: View {
    let onClose: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.themeSelection) private var themeSelection
    @AppStorage("cableScanlines") private var cableScanlinesEnabled = true
    @FocusState private var focusedThemeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack {
                Text(theme.usesCableLayout ? "SETTINGS" : "Theme Mode")
                    .font(theme.heading(62))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                GuideBackButton(onBack: onClose)
            }
            .padding(.horizontal, 12)

            HStack(alignment: .top, spacing: 72) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 18) {
                            if theme.usesCableLayout {
                                scanlinesButton
                            }
                            ForEach(Theme.catalog) { option in
                                themeButton(for: option).id(option.id)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear { proxy.scrollTo(theme.id, anchor: .center) }
                }
                if theme.usesCableLayout {
                    aboutPanel
                        .frame(width: 500, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: theme.usesCableLayout ? 1700 : 1040)
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.screenBackground.ignoresSafeArea())
        .cableScanlines()
        .defaultFocus($focusedThemeID, theme.id)
        .onExitCommand(perform: onClose)
    }

    private var scanlinesButton: some View {
        Button {
            cableScanlinesEnabled.toggle()
        } label: {
            HStack {
                Text("CRT scanlines").foregroundStyle(theme.primaryText)
                Spacer()
                Text(cableScanlinesEnabled ? "ON" : "OFF").foregroundStyle(theme.accent)
            }
            .font(theme.label(32))
        }
        .buttonStyle(SpelunkrActionButtonStyle(background: AnyShapeStyle(theme.panelFill)))
        .accessibilityLabel("CRT scanlines")
        .accessibilityValue(cableScanlinesEnabled ? Text("On") : Text("Off"))
    }

    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("ABOUT")
                .font(theme.heading(34))
                .foregroundStyle(theme.accent)
                .accessibilityAddTraits(.isHeader)
            Text("An unofficial Apple TV client for spelunkr.tv.")
            Text("Channels follow a shared broadcast schedule. Programs stream from the Internet Archive.")
            Text("Music credits appear during station breaks.")
        }
        .font(theme.body(29))
        .foregroundStyle(theme.softText)
        .padding(.top, 14)
    }

    private func themeButton(for option: Theme) -> some View {
        let isSelected = option.id == theme.id

        return Button {
            if let themeSelection {
                themeSelection.wrappedValue = option.id
            }
            onClose()
        } label: {
            HStack(spacing: 26) {
                swatch(for: option)

                VStack(alignment: .leading, spacing: 6) {
                    Text(option.name)
                        .font(theme.heading(theme.guideLayout == .largePrint ? 46 : 36))
                        .foregroundStyle(theme.primaryText)
                    Text(option.summary)
                        .font(theme.body(theme.guideLayout == .largePrint ? 38 : 26))
                        .foregroundStyle(theme.softText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(theme.focusBorder)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(SpelunkrActionButtonStyle(
            background: isSelected ? theme.selectedRowFill : AnyShapeStyle(theme.panelFill),
            restingBorder: isSelected ? theme.selectedBorder : theme.controlBorder,
            horizontalPadding: 24,
            verticalPadding: 20
        ))
        .focused($focusedThemeID, equals: option.id)
        .accessibilityLabel(Text(option.name))
        .accessibilityHint(Text(option.summary))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func swatch(for option: Theme) -> some View {
        Canvas { context, size in
            let scaleX = size.width / 100, scaleY = size.height / 60
            func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                let rect = CGRect(x: x * scaleX, y: y * scaleY, width: w * scaleX, height: h * scaleY)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
            let accent = option.accent, detail = option.secondaryAccent, panel = option.raisedSurface
            switch option.guideLayout {
            case .timeline:
                block(option.usesCableLayout ? 63 : 5, 5, 32, 20, panel)
                block(option.usesCableLayout ? 5 : 42, 8, 47, 5, accent)
                for row in 0..<3 {
                    let y = CGFloat(29 + row * 9)
                    block(5, y, 19, 6, detail)
                    block(27, y, 68, 6, panel)
                }
            case .daylight:
                block(5, 5, 32, 20, panel)
                block(43, 10, 44, 5, accent)
                for row in 0..<3 {
                    let y = CGFloat(30 + row * 9)
                    block(5, y, 25, 6, detail)
                    block(33, y, 29, 6, panel)
                    block(65, y, 30, 6, panel)
                }
            case .cinema:
                block(5, 5, 63, 38, panel)
                block(5, 48, 38, 5, accent)
                for row in 0..<4 { block(73, CGFloat(5 + row * 13), 22, 9, detail) }
            case .channelWall:
                block(5, 5, 30, 20, panel)
                block(40, 10, 47, 5, accent)
                for row in 0..<2 {
                    for col in 0..<4 {
                        block(CGFloat(5 + col * 23), CGFloat(29 + row * 14), 21, 11,
                              row == 0 && col == 0 ? accent : panel)
                    }
                }
            case .scheduleDesk:
                block(5, 5, 23, 50, panel)
                for row in 0..<4 {
                    let y = CGFloat(7 + row * 12)
                    block(33, y, 13, 5, detail)
                    block(50, y, 41, 5, accent)
                }
            case .largePrint:
                for row in 0..<3 {
                    let y = CGFloat(6 + row * 17)
                    block(6, y, 14, 12, accent)
                    block(26, y + 2, 65, 8, option.primaryText)
                }
            case .spotlight:
                for row in 0..<2 {
                    let y = CGFloat(5 + row * 27)
                    block(5, y, 22, 3, row == 0 ? accent : detail)
                    for col in 0..<3 { block(CGFloat(5 + col * 31), y + 7, 27, 14, panel) }
                }
            }
        }
        .background(option.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(option.controlBorder, lineWidth: 2) }
        .frame(width: 100, height: 60)
        .accessibilityHidden(true)
    }
}
