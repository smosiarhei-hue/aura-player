import SwiftUI

/// The palette picker is separate from sound and typography settings.
struct SonivoAppearanceView: View {
    @State private var themeManager = ThemeFontManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var l10n = SonivoL10n.shared
    @State private var iconManager = AppIconManager.shared

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
                     ? "Цвет сохраняется и меняется без перезапуска. Фон плеера остаётся под цвет обложки. Иконка приложения выбирается отдельно."
                     : "Your color is saved without restarting. The player keeps its artwork colors. Choose the app icon separately.")
            }
            Section {
                NavigationLink {
                    AppIconPickerView()
                } label: {
                    HStack(spacing: 14) {
                        AppIconThumbnail(icon: iconManager.selected ?? .music)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.isRussian ? "Иконка приложения" : "App icon")
                            Text(iconManager.selected?.title(russian: l10n.isRussian)
                                 ?? (l10n.isRussian ? "Другая иконка" : "Other icon"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SN.bg)
        .navigationTitle(l10n.isRussian ? "Оформление" : "Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { iconManager.synchronize() }
    }

    private func select(_ theme: AppThemeColor) {
        Haptics.tap(.light)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            themeManager.selectedTheme = theme
        }
    }
}
