import SwiftUI

struct SettingsView: View {
    @State private var settings = SettingsStore.shared
    @State private var library = LibraryStore.shared
    @State private var player = PlayerCore.shared
    @State private var ym = YandexMusicService.shared
    @State private var socialAuth = SocialAuthStore.shared
    @State private var themeManager = ThemeFontManager.shared
    @State private var l10n = SonivoL10n.shared
    @State private var mediaCache = MediaCacheManager.shared
    @State private var musixmatch = MusixmatchSettings.shared
    @State private var musixmatchProxyInput = ""
    @State private var musixmatchKeyInput = ""
    @State private var musixmatchKeyMessage = ""
    @State private var showYandexAuthSheet = false
    @State private var showEqualizerSheet = false
    @State private var isSyncingLikes = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Яндекс Музыка") {
                    if let user = ym.currentUser {
                        HStack(spacing: 14) {
                            if let avatar = user.avatarUrl {
                                RemoteArtwork(urlString: avatar, corner: 999).frame(width: 52, height: 52)
                            } else {
                                ZStack {
                                    Circle().fill(LinearGradient(colors: [SN.ember, SN.amber], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 52, height: 52)
                                    Text(String(user.displayName?.prefix(1) ?? user.login.prefix(1)).uppercased()).font(SN.text(.title3, .bold)).foregroundStyle(SN.ink)
                                }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.displayName ?? user.login).font(SN.text(.callout, .bold)).foregroundStyle(.primary)
                                Text("@\(user.login)").font(SN.text(.footnote)).foregroundStyle(.secondary)
                                if user.hasPlus {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.seal.fill").font(SN.text(.caption2)).foregroundStyle(SN.ember)
                                        Text("Яндекс Плюс").font(SN.text(.caption2, .semibold)).foregroundStyle(SN.ember)
                                    }.padding(.top, 2)
                                }
                            }
                        }.padding(.vertical, 4)
                        Button {
                            Task { isSyncingLikes = true; await ym.syncAccountData(); isSyncingLikes = false }
                        } label: {
                            HStack { Image(systemName: "arrow.triangle.2.circlepath"); Text(isSyncingLikes ? "Синхронизация..." : "Синхронизировать медиатеку") }
                        }.disabled(isSyncingLikes)
                        Button(role: .destructive) { ym.logout() } label: { Text("Выйти из Яндекс ID") }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Войдите в свой Яндекс ID, чтобы слушать персональную Мою волну и синхронизировать любимую музыку.").font(SN.text(.footnote)).foregroundStyle(.secondary)
                            Button { showYandexAuthSheet = true } label: {
                                HStack(spacing: 8) { Image(systemName: "person.badge.key.fill"); Text("Войти с Яндекс ID") }
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }.buttonStyle(.borderedProminent).tint(SN.ember)
                        }.padding(.vertical, 4)
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

                Section {
                    // Цветовая тема (Apple Crimson, Amber Sunset, Electric Violet, Neon Cyan, Emerald Glow, Cobalt Blue)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.isRussian ? "Цветовая тема" : "Accent Theme")
                            .font(SN.text(.subheadline, .medium))
                            .foregroundStyle(.primary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(AppThemeColor.allCases) { theme in
                                    Button {
                                        Haptics.tap(.light)
                                        themeManager.selectedTheme = theme
                                    } label: {
                                        VStack(spacing: 6) {
                                            ZStack {
                                                Circle()
                                                    .fill(theme.color)
                                                    .frame(width: 36, height: 36)
                                                    .shadow(color: theme.color.opacity(0.35), radius: 4, y: 2)

                                                if themeManager.selectedTheme == theme {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 14, weight: .bold))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(
                                                        themeManager.selectedTheme == theme ? Color.white : Color.clear,
                                                        lineWidth: 2
                                                    )
                                            )

                                            Text(theme.displayName)
                                                .font(SN.text(.caption2, themeManager.selectedTheme == theme ? .bold : .regular))
                                                .foregroundStyle(themeManager.selectedTheme == theme ? .primary : .secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(width: 76)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)

                    // 5 Шрифтов: Neue Montreal, Satoshi, General Sans, Instrument Sans, PP Neue Machina
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.isRussian ? "Шрифт приложения (5 вариантов)" : "Typography (5 Fonts)")
                            .font(SN.text(.subheadline, .medium))
                            .foregroundStyle(.primary)
                            .padding(.top, 4)

                        ForEach(AppCustomFont.allCases) { font in
                            Button {
                                Haptics.tap(.light)
                                themeManager.selectedFont = font
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(font.displayName)
                                                .font(themeManager.font(style: .body, weight: themeManager.selectedFont == font ? .bold : .regular))
                                                .foregroundStyle(.primary)

                                            if themeManager.selectedFont == font {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(themeManager.accentColor)
                                                    .font(.caption)
                                            }
                                        }

                                        Text(font.subtitle)
                                            .font(SN.text(.caption2))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(font.sampleText)
                                        .font(SN.text(.footnote, .medium))
                                        .foregroundStyle(themeManager.selectedFont == font ? themeManager.accentColor : .secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(themeManager.selectedFont == font ? themeManager.accentColor.opacity(0.14) : Color.white.opacity(0.06))
                                        )
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(l10n.isRussian ? "Оформление и шрифты" : "Theme & Typography")
                } footer: {
                    Text(l10n.isRussian ? "Выбранный шрифт и тема мгновенно применяются ко всем экранам, карточкам и элементам управления Sonivo." : "The selected font and theme color dynamically apply across all views and controls in Sonivo.")
                }

                Section {
                    Picker(l10n.isRussian ? "Язык" : "Language", selection: $l10n.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(l10n.isRussian ? "Язык интерфейса" : "Interface Language")
                } footer: {
                    Text(l10n.isRussian ? "Sonivo работает на русском языке по умолчанию. Доступно быстрое переключение на английский." : "Sonivo defaults to Russian with fast switching to English.")
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.isRussian ? "Плавность ProMotion (до 120 Гц)" : "ProMotion High Refresh Rate")
                                .font(SN.text(.subheadline, .medium))
                            Text(l10n.isRussian ? "Мягкая инерция пролистывания и плавная кинетика скролла без резких остановок" : "Smooth weighted scroll inertia and buttery deceleration")
                                .font(SN.text(.caption2))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "waveform.path.badge.plus")
                            .font(.title3)
                            .foregroundStyle(themeManager.accentColor)
                    }
                } header: {
                    Text(l10n.isRussian ? "Кинетика и пролистывание" : "Scroll Kinetics")
                }

                Section {
                    Button {
                        showEqualizerSheet = true
                    } label: {
                        HStack {
                            Label("Эквалайзер", systemImage: "slider.vertical.3")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(eqSummary)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Toggle("Только для наушников", isOn: $player.eqHeadphonesOnly)
                        .tint(settings.accentColor)

                    HStack {
                        Label("Текущий вывод", systemImage: player.isHeadphonesConnected ? "headphones" : "iphone")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(eqRouteSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Звук")
                } footer: {
                    Text("Нативный 10-полосный EQ работает локально. Режим «Только для наушников» при необходимости оставляет динамик телефона в Flat.")
                }

                Section {
                    Toggle("Dolby Atmos (Пространственное аудио)", isOn: $player.spatialAudioEnabled)
                        .tint(settings.accentColor)

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
                } header: {
                    Text("Качество звука и Dolby Atmos")
                } footer: {
                    Text("Lossless воспроизводит оригинальный звук студийной записи (FLAC). Dolby Atmos воспроизводит объёмную пространственную панораму для AirPods и внешней акустики.")
                }

                Section {
                    ForEach([TransitionMode.gapless, TransitionMode.crossfade, TransitionMode.off], id: \.rawValue) { mode in
                        Button { player.transitionMode = mode } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    Text(mode.description).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if player.transitionMode == mode { Image(systemName: "checkmark").foregroundStyle(settings.accentColor) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if player.transitionMode == .crossfade {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("Длительность кроссфейда"); Spacer(); Text(String(format: "%.1f сек", player.crossfadeDuration)).foregroundStyle(.secondary) }
                            Slider(value: $player.crossfadeDuration, in: 1...12, step: 0.5).tint(settings.accentColor)
                        }
                    }
                } header: {
                    Text("Переходы между треками")
                } footer: {
                    Text("Gapless воспроизводит треки непрерывно в оригинальном качестве без искажений. Кроссфейд обеспечивает плавное затухание звука.")
                }

                Section {
                    Toggle("Тактильные сигналы музыки", isOn: $settings.musicHapticsEnabled)
                        .tint(settings.accentColor)

                    if settings.musicHapticsEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Сила вибрации")
                                Spacer()
                                Text(settings.musicHapticsIntensity.title)
                                    .foregroundStyle(.secondary)
                            }
                            Picker("Сила вибрации", selection: $settings.musicHapticsIntensity) {
                                ForEach(MusicHapticsIntensity.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: settings.musicHapticsIntensity) { _, newIntensity in
                                MusicHapticsManager.shared.playPreview(intensity: newIntensity)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Универсальный доступ")
                } footer: {
                    Text("Тактильные сигналы музыки в стиле Apple Music (iOS 18+). Taptic Engine передает ритм через раздельные тактильные ощущения: глубокий удар бочки (кик), четкие тарелочки (хай-хэт) и мягкий резонанс баса (808). Специально для тактильного восприятия музыки и людей с нарушениями слуха.")
                }
                .onChange(of: settings.musicHapticsEnabled) { _, isEnabled in
                    if isEnabled {
                        MusicHapticsManager.shared.playPreview(intensity: settings.musicHapticsIntensity)
                    }
                }

                Section("Тактильный отклик интерфейса") {
                    Toggle("Вибрация при управлении", isOn: $settings.hapticsEnabled).tint(settings.accentColor)
                    Toggle("Вибрация при перемотке", isOn: $settings.scrubHapticsEnabled).tint(settings.accentColor)
                }

                Section("Дизайн текста песен") {
                    Picker("Оформление", selection: $settings.lyricsDesign) {
                        ForEach(LyricsDesign.allCases) { design in
                            Text(design.title).tag(design)
                        }
                    }
                    .pickerStyle(.menu)
                    LyricsDesignPreview(design: settings.lyricsDesign)
                }

                Section {
                    Toggle("Apple Neural Engine", isOn: $settings.isNeuralEngineEnabled)
                        .tint(settings.accentColor)

                    LabeledContent {
                        Text(musixmatch.hasProxyURL ? "Прокси подключён" : (musixmatch.hasAPIKey ? "Прямой API" : "Не настроен"))
                            .foregroundStyle((musixmatch.hasProxyURL || musixmatch.hasAPIKey) ? Color.green : Color.secondary)
                    } label: {
                        Label("Musixmatch RichSync", systemImage: "text.badge.checkmark")
                    }

                    TextField("https://api.example.com", text: $musixmatchProxyInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onAppear {
                            if musixmatchProxyInput.isEmpty {
                                musixmatchProxyInput = musixmatch.proxyBaseURLString
                            }
                        }

                    HStack {
                        Button("Сохранить прокси") {
                            if musixmatch.saveProxyURL(musixmatchProxyInput) {
                                musixmatchProxyInput = musixmatch.proxyBaseURLString
                                musixmatchKeyMessage = "Прокси подключён. Ключ остаётся на сервере"
                                LyricsService.shared.invalidateCache()
                                NotificationCenter.default.post(name: .didUpdateCustomLyrics, object: nil)
                            } else {
                                musixmatchKeyMessage = "Введите корректный HTTPS URL без query-параметров"
                            }
                        }
                        .disabled(musixmatchProxyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Spacer()

                        if musixmatch.hasProxyURL {
                            Button("Удалить прокси", role: .destructive) {
                                musixmatch.removeProxyURL()
                                musixmatchProxyInput = musixmatch.proxyBaseURLString
                                musixmatchKeyMessage = "Прокси удалён"
                                LyricsService.shared.invalidateCache()
                                NotificationCenter.default.post(name: .didUpdateCustomLyrics, object: nil)
                            }
                        }
                    }

                    Divider()

                    Text("Резервный прямой доступ")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SecureField(
                        musixmatch.hasAPIKey ? "Partner API Key сохранён" : "Необязательный Musixmatch API Key",
                        text: $musixmatchKeyInput
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    HStack {
                        Button("Сохранить ключ") {
                            if musixmatch.saveAPIKey(musixmatchKeyInput) {
                                musixmatchKeyInput = ""
                                musixmatchKeyMessage = "Резервный ключ сохранён в Keychain"
                                LyricsService.shared.invalidateCache()
                                NotificationCenter.default.post(name: .didUpdateCustomLyrics, object: nil)
                            } else {
                                musixmatchKeyMessage = "Введите действующий ключ"
                            }
                        }
                        .disabled(musixmatchKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Spacer()

                        if musixmatch.hasAPIKey {
                            Button("Удалить ключ", role: .destructive) {
                                musixmatch.removeAPIKey()
                                musixmatchKeyInput = ""
                                musixmatchKeyMessage = "Резервный ключ удалён"
                                LyricsService.shared.invalidateCache()
                                NotificationCenter.default.post(name: .didUpdateCustomLyrics, object: nil)
                            }
                        }
                    }

                    if !musixmatchKeyMessage.isEmpty {
                        Text(musixmatchKeyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Размер шрифта"); Spacer(); Text("\(Int(settings.lyricsFontSize)) pt").foregroundStyle(.secondary) }
                        Slider(value: $settings.lyricsFontSize, in: 36...60, step: 1).tint(settings.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Сдвиг синхронизации"); Spacer(); Text(String(format: "%+.1f сек", settings.lyricsOffset)).foregroundStyle(.secondary) }
                        Slider(value: $settings.lyricsOffset, in: -3...3, step: 0.1).tint(settings.accentColor)
                    }
                } header: {
                    Text("Караоке (текст песни)")
                } footer: {
                    Text("Караоке включается только с таймкодами подходящей версии песни. Без таймкодов показывается обычный текст. Авторазметка по длительности и автоматическая публикация распознанных слов отключены.")
                }

                Section("Медиатека") {
                    LabeledContent("Всего треков в приложении", value: "\(library.tracks.count)")
                    Button("Пересканировать память") { Task { await library.rescan() } }
                    Button("Сбросить индекс медиатеки", role: .destructive) { library.resetIndex() }
                }

                Section {
                    LabeledContent("Кэш аудио, обложек и видео", value: mediaCache.formattedSize)
                    Button(role: .destructive) {
                        Task { await mediaCache.clearGeneratedCache() }
                    } label: {
                        HStack {
                            Text(mediaCache.isClearing ? "Очистка…" : "Очистить сгенерированный кэш")
                            if mediaCache.isClearing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(mediaCache.isClearing)
                } header: {
                    Text("Хранилище")
                } footer: {
                    Text("Личные импортированные треки не удаляются. Очищаются только повторно загружаемые аудиофайлы, обложки и AI-видео.")
                }

                Section("О приложении") {
                    LabeledContent("Название", value: "Sonivo")
                    LabeledContent("Версия", value: appVersion)
                    LabeledContent("Сборка", value: "Build #\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                    LabeledContent("Дизайн", value: "Liquid Glass")
                }
            }
            .navigationTitle("Настройки")
            .scrollContentBackground(.hidden)
            .background(SonivoScreenBackground(colors: [SN.bgRaised, SN.bg, SN.card], showsMesh: false))
            .listRowBackground(SN.card.opacity(0.78))
            .listRowSeparatorTint(SN.ink.opacity(0.10))
            .tint(settings.accentColor)
            .sheet(isPresented: $showYandexAuthSheet) { YandexAuthSheet() }
            .sheet(isPresented: $showEqualizerSheet) { PlayerEQSheetView() }
            .task { await mediaCache.refresh() }
        }
    }

    private var eqSummary: String {
        if !player.eqEnabled { return "Выключен" }
        if player.isEQPreparingNativeStream { return "Подготовка" }
        if player.eqHeadphonesOnly && !player.isHeadphonesConnected { return "В наушниках" }
        return "Включён"
    }

    private var eqRouteSummary: String {
        if player.isEQPreparingNativeStream { return "Поток кэшируется для нативного EQ" }
        if player.isHeadphonesConnected { return "Наушники • EQ активен" }
        if player.eqHeadphonesOnly { return "Динамик • Flat" }
        return "Динамик • EQ активен"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "\(version) Beta"
    }
}
