import SwiftUI

struct SettingsView: View {
    @State private var settings = SettingsStore.shared
    @State private var library = LibraryStore.shared
    @State private var player = PlayerCore.shared
    @State private var ym = YandexMusicService.shared
    @State private var socialAuth = SocialAuthStore.shared
    @State private var tokenInput = ""

    @State private var isCheckingGemini = false
    @State private var geminiCheckResult: String? = nil
    @State private var geminiCheckIsError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Яндекс Музыка (YM-API)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OAuth токен аккаунта").font(.subheadline.weight(.medium))
                        SecureField("Вставьте токен Яндекс Музыки", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { tokenInput = ym.token }
                        Button { ym.token = tokenInput } label: {
                            Text(ym.isAuthorized ? "Токен сохранен ✓" : "Сохранить токен").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "#FF455B") ?? .pink)
                        Text("Токен позволяет слушать музыку в максимальном качестве 320 kbps и запускать персональную «Мою волну».")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }

                Section("Аккаунт") {
                    if socialAuth.isSignedIn {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(socialAuth.displayName ?? "Пользователь Apple").font(.subheadline.weight(.medium))
                                Text("Избранное привязано к этому аккаунту").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Button("Выйти", role: .destructive) { socialAuth.signOut() }
                    } else {
                        SignInWithAppleView { userID, name in socialAuth.handleSuccess(userID: userID, name: name) }
                    }
                }

                Section("Качество звука") {
                    ForEach(AudioQuality.allCases) { quality in
                        Button { player.selectQuality(quality) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(quality.label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    Text(quality.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if player.audioQuality == quality { Image(systemName: "checkmark").foregroundStyle(settings.accentColor) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }

                Section("Оформление") {
                    Picker("Тема", selection: $settings.theme) { ForEach(AppTheme.allCases) { Text($0.name).tag($0) } }
                    HStack {
                        Text("Цветовой акцент"); Spacer()
                        ForEach(AccentChoice.allCases) { accent in
                            Button { settings.accent = accent } label: {
                                Circle().fill(LinearGradient(colors: accent.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(settings.accent == accent ? Color.primary : .clear, lineWidth: 2.5))
                            }.buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    ForEach(TransitionMode.allCases) { mode in
                        Button { player.transitionMode = mode } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    Text(mode.description).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if player.transitionMode == mode { Image(systemName: "checkmark").foregroundStyle(settings.accentColor) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if player.transitionMode == .crossfade {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("Длительность кроссфейда"); Spacer(); Text(String(format: "%.1f сек", player.crossfadeDuration)).foregroundStyle(.secondary) }
                            Slider(value: $player.crossfadeDuration, in: 1...12, step: 0.5).tint(settings.accentColor)
                        }
                    }
                } header: { Text("Переходы между песнями") } footer: {
                    Text("В AutoMix нет ручной длины и стиля: он сам анализирует BPM, такты, структуру и тональность, выбирает 4/8/16 тактов, синхронизирует темп и автоматически применяет beat-loop, фильтры и reverb.")
                }

                Section {
                    Button {
                        Task {
                            isCheckingGemini = true
                            geminiCheckResult = nil
                            let status = await GeminiAutoMixPlanner.shared.testConnectivity()
                            isCheckingGemini = false
                            switch status {
                            case .ok(let model):
                                geminiCheckIsError = false
                                geminiCheckResult = "✅ Gemini отвечает (\(model)). AutoMix сейчас будет использовать AI-план."
                            case .regionBlocked(let message):
                                geminiCheckIsError = true
                                geminiCheckResult = "🚫 Google заблокировал запрос по региону/ключу: \(message)"
                            case .httpError(let code, let message):
                                geminiCheckIsError = true
                                geminiCheckResult = "⚠️ Ошибка Gemini (HTTP \(code)): \(message)"
                            case .networkError(let message):
                                geminiCheckIsError = true
                                geminiCheckResult = "⚠️ Сетевая ошибка: \(message)"
                            case .noApiKey:
                                geminiCheckIsError = true
                                geminiCheckResult = "⚠️ API-ключ Gemini не настроен."
                            }
                        }
                    } label: {
                        HStack {
                            Text("Проверить подключение к Gemini")
                            Spacer()
                            if isCheckingGemini { ProgressView() }
                        }
                    }
                    .disabled(isCheckingGemini)

                    if let geminiCheckResult {
                        Text(geminiCheckResult)
                            .font(.caption)
                            .foregroundStyle(geminiCheckIsError ? .red : .green)
                    }
                } header: { Text("Диагностика Gemini AI") } footer: {
                    Text("Отправляет прямо сейчас короткий тестовый запрос в Gemini API. Включите или выключите VPN и нажмите ещё раз, чтобы увидеть актуальный результат для текущего подключения.")
                }

                Section("Тактильный отклик") {
                    Toggle("Вибрация при управлении", isOn: $settings.hapticsEnabled).tint(settings.accentColor)
                    Toggle("Вибрация при перемотке", isOn: $settings.scrubHapticsEnabled).tint(settings.accentColor)
                }

                Section("Караоке (текст песни)") {
                    Toggle("Строка текста в плеере", isOn: $settings.showTeleprompterInPlayer).tint(settings.accentColor)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Размер шрифта"); Spacer(); Text("\(Int(settings.lyricsFontSize)) pt").foregroundStyle(.secondary) }
                        Slider(value: $settings.lyricsFontSize, in: 36...60, step: 1).tint(settings.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Сдвиг синхронизации"); Spacer(); Text(String(format: "%+.1f сек", settings.lyricsOffset)).foregroundStyle(.secondary) }
                        Slider(value: $settings.lyricsOffset, in: -3...3, step: 0.1).tint(settings.accentColor)
                    }
                }

                Section("Медиатека") {
                    LabeledContent("Всего треков в приложении", value: "\(library.tracks.count)")
                    Button("Пересканировать память") { Task { await library.rescan() } }
                    Button("Сбросить индекс медиатеки", role: .destructive) { library.resetIndex() }
                }

                Section("О приложении") {
                    LabeledContent("Название", value: "Sonivo")
                    LabeledContent("Версия", value: appVersion)
                    LabeledContent("Сборка", value: "Build #\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                    LabeledContent("Дизайн", value: "iOS 27 Liquid Glass")
                }
            }.navigationTitle("Настройки")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "\(version) Beta"
    }
}
