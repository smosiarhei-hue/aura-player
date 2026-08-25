import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Оформление") {
                    Picker("Тема", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { t in Text(t.name).tag(t) }
                    }

                    HStack {
                        Text("Цветовой акцент")
                        Spacer()
                        ForEach(AccentChoice.allCases) { a in
                            Button { settings.accent = a } label: {
                                Circle()
                                    .fill(LinearGradient(colors: a.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(settings.accent == a ? Color.primary : .clear, lineWidth: 2.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Воспроизведение и Automix") {
                    Toggle("Automix (бесшовный кроссфейд)", isOn: $player.automixEnabled)
                        .tint(settings.accentColor)

                    if player.automixEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Длительность перехода")
                                Spacer()
                                Text(String(format: "%.1f сек", player.automixDuration))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $player.automixDuration, in: 1.0...5.0, step: 0.5)
                                .tint(settings.accentColor)
                        }
                    }
                }

                Section("Тактильный отклик") {
                    Toggle("Вибрация при управлении", isOn: $settings.hapticsEnabled)
                        .tint(settings.accentColor)
                    Toggle("Вибрация при перемотке", isOn: $settings.scrubHapticsEnabled)
                        .tint(settings.accentColor)
                }

                Section("Медиатека") {
                    LabeledContent("Всего треков в приложении", value: "\(library.tracks.count)")
                    Button("Пересканировать память") {
                        Task { await library.rescan() }
                    }
                    Button(role: .destructive) {
                        library.resetIndex()
                    } label: {
                        Text("Сбросить индекс медиатеки")
                    }
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: "1.0.0")
                    LabeledContent("Дизайн", value: "iOS 27 Liquid Glass")
                    Text("Aurora Player — премиальный музыкальный плеер со спектральным анализом, 10-полосным эквалайзером и динамическими обложками.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
        }
    }
}
