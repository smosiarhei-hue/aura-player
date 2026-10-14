import SwiftUI

/// The palette picker is separate from sound and typography settings.
struct SonivoAppearanceView: View {
    @State private var themeManager = ThemeFontManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var l10n = SonivoL10n.shared
    @State private var iconManager = AppIconManager.shared

    @AppStorage(SonivoCaptureBrand.visibleKey) private var showCaptureBrand = true
    @AppStorage(SonivoLiveActivityController.enabledKey) private var liveActivityEnabled = true

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
                     ? "Тема меняется сразу. Фон плеера подстраивается под обложку."
                     : "Changes apply immediately. The player background follows its artwork.")
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
            Section {
                Toggle(l10n.isRussian ? "Бренд на экране" : "On-screen branding", isOn: $showCaptureBrand)
                Toggle("Dynamic Island", isOn: $liveActivityEnabled)
                    .disabled(!SonivoLiveActivityController.isEmbedded)
            } header: {
                Text(l10n.isRussian ? "Sonivo на экране" : "Sonivo on screen")
            } footer: {
                Text(l10n.isRussian
                     ? "Фирменная строка видна до скриншота; при записи экрана появляется автоматически. Системный индикатор записи не меняется."
                     : "Branding is visible before a screenshot and appears automatically during screen capture. System recording indicators are unchanged.")
                if !SonivoLiveActivityController.isEmbedded {
                    Text(l10n.isRussian
                         ? "Для Dynamic Island требуется сборка с подписанным Live Activity-расширением. В этой сборке доступна фирменная строка внутри приложения."
                         : "Dynamic Island requires a signed Live Activity extension. This build supports in-app branding.")
                }
            }
        }
        .modifier(SonivoSettingsFormStyle())
        .navigationTitle(l10n.isRussian ? "Тема и иконка" : "Theme & icon")
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
