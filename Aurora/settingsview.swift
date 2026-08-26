import SwiftUI

// MARK: - Settings View (Sonivo Settings)

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @StateObject private var ym = YandexMusicService.shared
    @StateObject private var socialAuth = SocialAuthStore.shared
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
                        .tint(Color(hex: "#FF455B") ?? .pink)

                        Text("Токен позволяет слушать музыку в максимальном качестве 320 kbps и запускать персональную «Мою волну». Поиск и чарты работают и без токена.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Аккаунт") {
                    if socialAuth.isSignedIn {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(socialAuth.displayName ?? "Пользователь Apple")
                                    .font(.subheadline.weight(.medium))
                                Text("Избранное привязано к этому аккаунту")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            socialAuth.signOut()
                        } label: {
                            Text("Выйти")
                        }
                    } else {
                        SignInWithAppleView { userID, name in
                            socialAuth.handleSuccess(userID: userID, name: name)
                        }
                        Text("Вход через Apple привязывает избранное к вашему аккаунту. Полная синхронизация между устройствами потребует серверной части.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Качество звука") {
                    ForEach(AudioQuality.allCases) { q in
                        Button {
                            player.selectQuality(q)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(q.label)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(q.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if player.audioQuality == q {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(settings.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
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

                Section("Переходы между треками") {
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

                Section("Караоке (текст песни)") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Размер шрифта")
                            Spacer()
                            Text("\(Int(settings.lyricsFontSize)) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.lyricsFontSize, in: 36...60, step: 1)
                            .tint(settings.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Цвет подсветки")
                            .font(.subheadline)
                        HStack(spacing: 12) {
                            ForEach(SettingsStore.lyricsHighlightPresets) { preset in
                                Button {
                                    settings.lyricsHighlightHex = preset.hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: preset.hex) ?? .pink)
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle().strokeBorder(
                                                settings.lyricsHighlightHex == preset.hex ? Color.primary : .clear,
                                                lineWidth: 2.5
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Сдвиг синхронизации")
                            Spacer()
                            Text(String(format: "%+.1f сек", settings.lyricsOffset))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.lyricsOffset, in: -3.0...3.0, step: 0.1)
                            .tint(settings.accentColor)
                        Text("Сдвигает подсветку вперёд/назад, если текст не совпадает с музыкой.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
                    LabeledContent("Название", value: "Sonivo")
                    LabeledContent("Версия", value: appVersion)
                    LabeledContent("Сборка", value: "Build #\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                    LabeledContent("Дизайн", value: "iOS 27 Liquid Glass")
                    Text("Sonivo — премиальный плеер со спектральным анализом, 10-полосным эквалайзером, DJ AutoMix, Яндекс Музыкой (YM-API) и динамическими обложками.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
        }
    }

    private var appVersion: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "\(ver) Beta"
    }
}
