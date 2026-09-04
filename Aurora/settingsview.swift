import SwiftUI

struct SettingsView: View {
    @State private var settings = SettingsStore.shared
    @State private var library = LibraryStore.shared
    @State private var player = PlayerCore.shared
    @State private var ym = YandexMusicService.shared
    @State private var socialAuth = SocialAuthStore.shared
    @State private var tokenInput = ""
    @State private var showYandexAuthSheet = false
    @State private var isSyncingLikes = false

    @State private var isCheckingGemini = false
    @State private var geminiCheckResult: String? = nil
    @State private var geminiCheckIsError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Яндекс Музыка") {
                    if let user = ym.currentUser {
                        HStack(spacing: 14) {
                            if let avatar = user.avatarUrl {
                                RemoteArtwork(urlString: avatar, corner: 999)
                                    .frame(width: 52, height: 52)
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [AG.ember, AG.amber], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 52, height: 52)
                                    Text(String(user.displayName?.prefix(1) ?? user.login.prefix(1)).uppercased())
                                        .font(AG.text(.title3, .bold))
                                        .foregroundStyle(.white)
                                }
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.displayName ?? user.login)
                                    .font(AG.text(.callout, .bold))
                                    .foregroundStyle(.primary)

                                Text("@\(user.login)")
                                    .font(AG.text(.footnote))
                                    .foregroundStyle(.secondary)

                                if user.hasPlus {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(AG.text(.caption2))
                                            .foregroundStyle(AG.ember)
                                        Text("Яндекс Плюс (320 kbps & FLAC)")
                                            .font(AG.text(.caption2, .semibold))
                                            .foregroundStyle(AG.ember)
                                    }
                                    .padding(.top, 2)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        Button {
                            Task {
                                isSyncingLikes = true
                                await ym.syncAccountData()
                                isSyncingLikes = false
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text(isSyncingLikes ? "Синхронизация..." : "Синхронизировать медиатеку")
                            }
                        }
                        .disabled(isSyncingLikes)

                        Button(role: .destructive) {
                            ym.logout()
                        } label: {
                            Text("Выйти из Яндекс ID")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Войдите в свой Яндекс ID, чтобы слушать персональную Мою волну, синхронизировать всю любимую музыку и сохранять историю.")
                                .font(AG.text(.footnote))
                                .foregroundStyle(.secondary)

                            Button {
                                showYandexAuthSheet = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.badge.key.fill")
                                        .font(AG.text(.subheadline, .bold))
                                    Text("Войти с Яндекс ID")
                                        .font(AG.text(.subheadline, .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AG.ember)
                        }
                        .padding(.vertical, 4)
                    }
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
                    LabeledContent("Дизайн", value: "Liquid Glass")
                }
            }
            .navigationTitle("Настройки")
            .sheet(isPresented: $showYandexAuthSheet) {
                YandexAuthSheet()
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "\(version) Beta"
    }
}
