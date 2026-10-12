import SwiftUI

/// The palette picker is separate from sound and typography settings.
struct SonivoAppearanceView: View {
    @State private var themeManager = ThemeFontManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var l10n = SonivoL10n.shared

    var body: some View {
        Form {
            Section(l10n.isRussian ? "Режим оформления" : "Appearance mode") {
                Picker(l10n.isRussian ? "Режим" : "Mode", selection: $themeManager.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                ForEach(AppThemeColor.allCases) { theme in
                    Button {
                        select(theme)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.darkCanvasColor)
                                Circle().fill(theme.swatchColor).padding(10)
                            }
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                            Text(theme.displayName).foregroundStyle(SN.ink)
                            Spacer()
                            if themeManager.selectedTheme == theme {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(theme.color)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.displayName)
                    .accessibilityValue(themeManager.selectedTheme == theme ? "Выбрано" : "Не выбрано")
                    .accessibilityAddTraits(themeManager.selectedTheme == theme ? .isSelected : [])
                }
            } header: {
                Text(l10n.isRussian ? "Цвет приложения" : "App color")
            } footer: {
                Text(l10n.isRussian
                     ? "Цвет сохраняется и меняется без перезапуска. Фон плеера остаётся под цвет обложки. Фирменная иконка — коралловая."
                     : "Your color is saved without restarting. The player keeps its artwork colors. The app icon stays coral.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SN.bg)
        .navigationTitle(l10n.isRussian ? "Оформление" : "Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ theme: AppThemeColor) {
        Haptics.tap(.light)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            themeManager.selectedTheme = theme
        }
    }
}
