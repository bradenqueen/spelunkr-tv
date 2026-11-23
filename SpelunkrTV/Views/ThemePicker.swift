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
    @FocusState private var focusedThemeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            Text("Theme Mode")
                .font(theme.heading(62))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 12)

            ScrollView {
                VStack(spacing: 18) {
                    ForEach(Theme.catalog) { option in
                        themeButton(for: option)
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: 1040)
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.screenBackground.ignoresSafeArea())
        .defaultFocus($focusedThemeID, theme.id)
        .onExitCommand(perform: onClose)
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
            .overlay {
                RoundedRectangle(cornerRadius: option.controlCornerRadius)
                    .strokeBorder(option.panelBorder, lineWidth: 2)
            }
            .frame(width: 94, height: 58)
            .accessibilityHidden(true)
    }
}
