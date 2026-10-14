import SwiftUI

struct SettingsView: View {
    var category: SonivoSettingsCategory? = nil
    @State private var showResetIndexConfirmation = false
    @State private var showClearCacheConfirmation = false
    @AppStorage(MusicCatalogSource.storageKey) private var catalogSourceRaw = MusicCatalogSource.yandex.rawValue
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
    @AppStorage("sonivo_videoshot_enabled") private var videoShotsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showYandexAuthSheet = false
    @State private var showEqualizerSheet = false
    @State private var isSyncingLikes = false

    @ViewBuilder
    var body: some View {
        if category == nil {
            NavigationStack { settingsForm }
        } else {
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            if let category {
                categoryContent(category)
            } else {
                overview
            }
        }
        .modifier(SonivoSettingsFormStyle())
        .accessibilityIdentifier("settings.screen." + (category?.rawValue ?? "overview"))
        .navigationTitle(category?.title(russian: l10n.isRussian)
                         ?? (l10n.isRussian ? "Настройки" : "Settings"))
        .navigationBarTitleDisplayMode(category == nil ? .large : .inline)
        .sheet(isPresented: $showYandexAuthSheet) { YandexAuthSheet() }
        .sheet(isPresented: $showEqualizerSheet) { PlayerEQSheetView() }
        .task { if category == .storage { await mediaCache.refresh() } }
        .confirmationDialog("Сбросить индекс?", isPresented: $showResetIndexConfirmation, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) { library.resetIndex() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Список треков и локальные плейлисты будут сброшены. Импортированные файлы останутся на устройстве; их можно просканировать заново.")
        }
        .confirmationDialog("Очистить кэш?", isPresented: $showClearCacheConfirmation, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { Task { await mediaCache.clearGeneratedCache() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Созданные видео будут удалены. Аудио и обложки загрузятся заново. Импортированные треки сохранятся.")
        }
    }

    @ViewBuilder
    private var overview: some View {
        Section(l10n.isRussian ? "Музыка" : "Music") {
            categoryLink(.music)
            categoryLink(.playback)
            categoryLink(.lyrics)
        }
        Section(l10n.isRussian ? "Приложение" : "App") {
            categoryLink(.appearance)
            categoryLink(.haptics)
        }
        Section(l10n.isRussian ? "Данные и информация" : "Data & information") {
            categoryLink(.storage)
            categoryLink(.about)
        }
    }

    private func categoryLink(_ category: SonivoSettingsCategory) -> some View {
        NavigationLink {
            SettingsView(category: category)
        } label: {
            SettingsNavigationRow(symbol: category.symbol,
                                  title: category.title(russian: l10n.isRussian),
                                  subtitle: category.subtitle(russian: l10n.isRussian))
        }
        .accessibilityIdentifier("settings.category." + category.rawValue)
    }

    @ViewBuilder
    private func categoryContent(_ category: SonivoSettingsCategory) -> some View {
        switch category {
        case .music: musicSettings
        case .playback: playbackSettings
        case .appearance: appearanceSettings
        case .lyrics: lyricsSettings
        case .lyricsSources: lyricsSourceSettings
        case .haptics: hapticsSettings
        case .storage: storageSettings
        case .about: aboutSettings
        }
    }

    @ViewBuilder
    private var musicSettings: some View {
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
                            HStack { Image(systemName: "arrow.triangle.2.circlepath"); Text(isSyncingLikes ? "Синхронизация…" : "Синхронизировать медиатеку") }
                        }.disabled(isSyncingLikes)
                        if let message = ym.accountSyncMessage {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Сменить аккаунт") { showYandexAuthSheet = true }
                        Button(role: .destructive) { ym.logout() } label: { Text("Выйти из Яндекс Музыки") }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Войдите для Моей волны и синхронизации медиатеки.").font(SN.text(.footnote)).foregroundStyle(.secondary)
                            Button { showYandexAuthSheet = true } label: {
                                HStack(spacing: 8) { Image(systemName: "person.badge.key.fill"); Text("Войти с Яндекс ID") }
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }.buttonStyle(.borderedProminent).tint(SN.ember)
                        }.padding(.vertical, 4)
                    }
                }

                Section("Аккаунт Apple") {
                    if socialAuth.isSignedIn {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(socialAuth.displayName ?? "Пользователь Apple").font(.subheadline.weight(.medium))
                                Text("Аккаунт для избранного").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Button("Выйти", role: .destructive) { socialAuth.signOut() }
                    } else {
                        SignInWithAppleView { userID, name in socialAuth.handleSuccess(userID: userID, name: name) }
                    }
                }

                Section {
                    Picker("Источник поиска", selection: $catalogSourceRaw) {
                        ForEach(MusicCatalogSource.allCases) { source in
                            Text(source.title).tag(source.rawValue)
                        }
                    }
                } header: { Text("Музыкальный каталог") } footer: {
                    Text("Spotify через wolfXspotify — только поиск, превью и открытие в Spotify. Выбор влияет только на поиск. Полные треки в Sonivo — из Яндекс Музыки или медиатеки. Запросы Spotify передаются неофициальному сервису spotify.xwolf.space, без токенов и данных Яндекса.")
                }

    }

    @ViewBuilder
    private var playbackSettings: some View {
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
                    Text("10-полосный эквалайзер. В режиме «Только для наушников» динамик воспроизводит звук без EQ.")
                }

                Section {
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
                    Text("Качество звука")
                } footer: {
                    Text("Выбранное качество — предпочтение. Доступный формат зависит от сервиса и трека; фактическое качество показано в плеере.")
                }

                Section {
                    Toggle("Системное пространственное аудио", isOn: $player.spatialAudioEnabled)
                        .tint(settings.accentColor)

                    Text(player.spatialAudioStatusText)
                        .font(SN.text(.footnote))
                        .foregroundStyle(SN.inkMuted)
                } header: {
                    Text("Пространственный звук")
                } footer: {
                    Text("Работает через iOS на совместимых наушниках. Режим выбирается в Пункте управления. Стерео не становится Dolby Atmos; для защищённых и Dolby-потоков EQ может быть недоступен.")
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
                    Text("Gapless — без пауз. Кроссфейд — плавное смешивание конца и начала треков.")
                }

    }

    @ViewBuilder
    private var appearanceSettings: some View {
                Section {
                    NavigationLink {
                        SonivoAppearanceView()
                    } label: {
                        Label(l10n.isRussian ? "Тема и иконка" : "Theme & icon", systemImage: "paintpalette")
                    }

                    // 5 Шрифтов: Neue Montreal, Satoshi, General Sans, Instrument Sans, PP Neue Machina
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.isRussian ? "Шрифт интерфейса" : "Interface font")
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
                    Text(l10n.isRussian ? "Внешний вид" : "Appearance")
                } footer: {
                    Text(l10n.isRussian ? "Тема и шрифт применяются сразу." : "Theme and font changes apply immediately.")
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
                    Text(l10n.isRussian ? "Язык меняется без перезапуска." : "Language changes without restarting.")
                }

                Section {
                    Toggle("Видеошоты", isOn: $videoShotsEnabled)
                } header: { Text("Видео в плеере") } footer: {
                    Text(reduceMotion
                         ? "В iOS включено уменьшение движения. Автовоспроизведение видео отключено."
                         : "Видео трека без звука. Если видео нет, показывается обложка.")
                }

    }

    @ViewBuilder
    private var lyricsSettings: some View {
                Section("Оформление текста") {
                    Picker("Оформление", selection: $settings.lyricsDesign) {
                        ForEach(LyricsDesign.allCases) { design in
                            Text(design.title).tag(design)
                        }
                    }
                    .pickerStyle(.menu)
                    LyricsDesignPreview(design: settings.lyricsDesign)
                }

                Section {
                    Toggle("Анализ на устройстве", isOn: $settings.isNeuralEngineEnabled)
                        .tint(settings.accentColor)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Размер шрифта"); Spacer(); Text("\(Int(settings.lyricsFontSize)) pt").foregroundStyle(.secondary) }
                        Slider(value: $settings.lyricsFontSize, in: 36...60, step: 1).tint(settings.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Сдвиг текста"); Spacer(); Text(String(format: "%+.1f сек", settings.lyricsOffset)).foregroundStyle(.secondary) }
                        Slider(value: $settings.lyricsOffset, in: -3...3, step: 0.1).tint(settings.accentColor)
                    }
                } header: {
                    Text("Синхронизация")
                } footer: {
                    Text("Караоке доступно с таймкодами нужной версии песни. Без них показывается обычный текст. Авторазметка по длительности и автоматическая публикация распознанных слов отключены.")
                }
                Section {
                    NavigationLink {
                        SettingsView(category: .lyricsSources)
                    } label: {
                        SettingsNavigationRow(symbol: "link", title: "Источники текста", subtitle: "Musixmatch · дополнительные настройки")
                    }
                }
    }

    @ViewBuilder
    private var lyricsSourceSettings: some View {
                Section {
                    LabeledContent {
                        Text(musixmatch.hasProxyURL ? "Через сервер" : (musixmatch.hasAPIKey ? "По API-ключу" : "Не настроен"))
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
                                musixmatchKeyMessage = "Адрес сохранён. API-ключ хранится на сервере."
                                LyricsService.shared.invalidateCache()
                                NotificationCenter.default.post(name: .didUpdateCustomLyrics, object: nil)
                            } else {
                                musixmatchKeyMessage = "Укажите HTTPS-адрес без параметров запроса."
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

                    Text("Прямой доступ · резервный")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SecureField(
                        musixmatch.hasAPIKey ? "API-ключ сохранён" : "API-ключ Musixmatch (необязательно)",
                        text: $musixmatchKeyInput
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    HStack {
                        Button("Сохранить ключ") {
                            if musixmatch.saveAPIKey(musixmatchKeyInput) {
                                musixmatchKeyInput = ""
                                musixmatchKeyMessage = "API-ключ сохранён в защищённом хранилище."
                                LyricsService.shared.invalidateCache()
                                NotificationCenter.default.post(name: .didUpdateCustomLyrics, object: nil)
                            } else {
                                musixmatchKeyMessage = "Проверьте API-ключ."
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

                } header: {
                    Text("Musixmatch")
                } footer: {
                    Text("Подключение через HTTPS-сервер предпочтительно: API-ключ остаётся на сервере. Для прямого доступа ключ сохраняется в Keychain.")
                }
    }

    @ViewBuilder
    private var hapticsSettings: some View {
                Section("Управление") {
                    Toggle("При нажатиях", isOn: $settings.hapticsEnabled).tint(settings.accentColor)
                    Toggle("При перемотке", isOn: $settings.scrubHapticsEnabled).tint(settings.accentColor)
                }

                Section {
                    Toggle("Вибрация под музыку", isOn: $settings.musicHapticsEnabled)
                        .tint(settings.accentColor)

                    if settings.musicHapticsEnabled {
                        Picker("Режим", selection: $settings.musicHapticsMode) {
                            ForEach(MusicHapticsMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.segmented)
                        Text(settings.musicHapticsMode.detail).font(.footnote).foregroundStyle(.secondary)
                        Toggle("Подстраивать силу под звук", isOn: $settings.musicHapticsAutomatic)
                        Text(MusicHapticsManager.shared.supportsHaptics ? MusicHapticsManager.shared.synchronization : "Устройство не поддерживает музыкальную вибрацию")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Проверить вибрацию") { MusicHapticsManager.shared.playPreview(intensity: settings.musicHapticsIntensity) }
                            .disabled(!MusicHapticsManager.shared.supportsHaptics)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(settings.musicHapticsAutomatic ? "Максимальная сила" : "Сила вибрации")
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
                    Text("Музыкальная вибрация")
                } footer: {
                    Text("Сильная использует весь диапазон Core Haptics. Отключите автоподстройку для фиксированной силы. Нужны открытое приложение и доступные аудиоданные; ощущения и задержка зависят от устройства и аудиомаршрута.")
                }
                .onChange(of: settings.musicHapticsMode) { _, _ in
                    MusicHapticsManager.shared.reset()
                    MusicHapticsManager.shared.playPreview(intensity: settings.musicHapticsIntensity)
                }
                .onChange(of: settings.musicHapticsEnabled) { _, isEnabled in
                    if isEnabled {
                        MusicHapticsManager.shared.playPreview(intensity: settings.musicHapticsIntensity)
                    } else { MusicHapticsManager.shared.stop() }
                }

    }

    @ViewBuilder
    private var storageSettings: some View {
                Section("Медиатека") {
                    LabeledContent("Треки", value: "\(library.tracks.count)")
                    Button("Обновить список треков") { Task { await library.rescan() } }
                    Button("Сбросить индекс", role: .destructive) { showResetIndexConfirmation = true }
                }

                Section {
                    LabeledContent("Размер кэша", value: mediaCache.formattedSize)
                    Button(role: .destructive) {
                        showClearCacheConfirmation = true
                    } label: {
                        HStack {
                            Text(mediaCache.isClearing ? "Очистка…" : "Очистить кэш")
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
                    Text("Удаляются загруженное аудио, обложки и созданные видео. Импортированные треки сохраняются.")
                }

    }

    @ViewBuilder
    private var aboutSettings: some View {
                Section("О приложении") {
                    LabeledContent("Название", value: "Sonivo")
                    LabeledContent("Версия", value: appVersion)
                    LabeledContent("Сборка", value: "Build #\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                    LabeledContent("Дизайн", value: "Liquid Glass")
                }
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.isRussian ? "Плавность интерфейса" : "Interface motion")
                                .font(SN.text(.subheadline, .medium))
                            Text(l10n.isRussian ? "Частота обновления зависит от устройства и настроек iOS." : "Refresh rate depends on your device and iOS settings.")
                                .font(SN.text(.caption2))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "waveform.path.badge.plus")
                            .font(.title3)
                            .foregroundStyle(themeManager.accentColor)
                    }
                } header: {
                    Text(l10n.isRussian ? "Интерфейс" : "Interface")
                }

    }

    private var eqSummary: String {
        if !player.eqEnabled { return "Выключен" }
        if player.isEQPreparingNativeStream { return "Подготовка" }
        if player.eqHeadphonesOnly && !player.isHeadphonesConnected { return "В наушниках" }
        return "Включён"
    }

    private var eqRouteSummary: String {
        if player.isEQPreparingNativeStream { return "Подготовка EQ" }
        if player.isHeadphonesConnected { return player.isEQEffectivelyActive ? "Наушники · EQ" : "Наушники" }
        if player.eqHeadphonesOnly { return "Динамик · без EQ" }
        return player.isEQEffectivelyActive ? "Динамик · EQ" : "Динамик"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "\(version) Beta"
    }
}
