import SwiftUI

/// The palette picker is separate from sound and typography settings.
struct SonivoAppearanceView: View {
    @State private var themeManager = ThemeFontManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var l10n = SonivoL10n.shared
    @State private var iconManager = AppIconManager.shared

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
                Toggle("Dynamic Island", isOn: $liveActivityEnabled)
                    .disabled(!SonivoLiveActivityController.isEmbedded)
            } header: {
                Text(l10n.isRussian ? "Воспроизведение вне приложения" : "Playback outside the app")
            } footer: {
                Text(l10n.isRussian
                     ? "Логотип и название Sonivo отображаются в системной Live Activity, когда это разрешает iOS. Индикатор записи экрана не меняется. Скриншот сохраняет уже видимый интерфейс."
                     : "The Sonivo logo and name appear in a system Live Activity when allowed by iOS. Screen recording indicators are unchanged. A screenshot captures the existing interface.")
                if !SonivoLiveActivityController.isEmbedded {
                    Text(l10n.isRussian
                         ? "Для Dynamic Island требуется сборка с подписанным Live Activity-расширением. В этой сборке оно пока недоступно."
                         : "Dynamic Island requires a signed Live Activity extension. It is not yet available in this build.")
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
