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
                ScrollView {
                    VStack(spacing: 18) {
                        if theme.usesCableLayout {
                            scanlinesButton
                        }
                        ForEach(Theme.catalog) { option in
                            themeButton(for: option)
                        }
                    }
                    .padding(12)
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
                        .font(theme.heading(36))
                        .foregroundStyle(theme.primaryText)
                    Text(option.summary)
                        .font(theme.body(26))
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
        RoundedRectangle(cornerRadius: option.controlCornerRadius)
            .fill(option.screenBackground)
            .overlay(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: option.cellCornerRadius)
                    .fill(option.focusedFill)
                    .frame(width: 44, height: 20)
                    .overlay {
                        RoundedRectangle(cornerRadius: option.cellCornerRadius)
                            .strokeBorder(option.focusBorder, lineWidth: 2)
                    }
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Capsule()
                    .fill(option.progressFill)
                    .frame(width: 36, height: 4)
                    .padding(12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: option.controlCornerRadius)
                    .strokeBorder(option.panelBorder, lineWidth: 2)
            }
            .frame(width: 94, height: 58)
            .accessibilityHidden(true)
    }
}
