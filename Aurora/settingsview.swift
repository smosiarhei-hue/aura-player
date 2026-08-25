import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @StateObject private var ym = YandexMusicService.shared
    @State private var tokenInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Яндекс Музыка (YM-API)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OAuth токен аккаунта")
                            .font(.subheadline.weight(.medium))

                        SecureField("Вставьте токен Яндекс Музыки", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .onAppear {
                                tokenInput = ym.token
                            }

                        Button {
                            ym.token = tokenInput
                        } label: {
                            Text(ym.isAuthorized ? "Токен сохранен ✓" : "Сохранить токен")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "#FF455B")!)

                        Text("Токен позволяет слушать музыку в максимальном качестве 320 kbps и запускать персональную «Мою волну». Поиск и чарты работают и без токена.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

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

                Section("Переходы между треками (Apple Music)") {
                    Picker("Режим перехода", selection: $player.transitionMode) {
                        ForEach(TransitionMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(player.transitionMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if player.transitionMode == .crossfade {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Время кроссфейда")
                                Spacer()
                                Text(String(format: "%.1f сек", player.crossfadeDuration))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $player.crossfadeDuration, in: 1.0...12.0, step: 0.5)
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
                    Text("Aurora Player — нативный плеер со спектральным анализом, 10-полосным эквалайзером, DJ AutoMix, Яндекс Музыкой (YM-API) и динамическими обложками.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
        }
    }
}
