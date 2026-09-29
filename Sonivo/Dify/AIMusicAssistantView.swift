import SwiftUI

// MARK: - Modern AI Music Studio & Curator View

struct AIMusicAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dify = DifyService.shared
    @ObservedObject private var store = AIMusicCuratorStore.shared
    @State private var player = PlayerCore.shared
    @State private var settings = SettingsStore.shared

    @State private var inputText: String = ""
    @State private var isSending = false
    @State private var showSettings = false
    @State private var showClearAlert = false
    @State private var selectedFilterCategory: ClarifyCategory? = nil
    @State private var extendingMessageId: UUID? = nil
    @State private var expandedPlaylistMessages: Set<UUID> = []
    @FocusState private var isInputFocused: Bool

    // MARK: - Curated Vibe Cards (Modern 2026 Matrix)
    private struct VibePreset: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let gradient: [Color]
        let prompt: String
    }

    private let vibePresets: [VibePreset] = [
        VibePreset(
            title: "Фонк для зала",
            subtitle: "Максимальный кач & бас",
            icon: "flame.fill",
            gradient: [Color(hex: "#FF455B") ?? .red, Color(hex: "#F97316") ?? .orange],
            prompt: "Составь энергичный мощный плейлист из 50 лучших треков в жанре Drift Phonk, агрессивный фонк и тренировочный хип-хоп для зала."
        ),
        VibePreset(
            title: "Ночной Синтвейв",
            subtitle: "Неон, трасса и 80-е",
            icon: "car.fill",
            gradient: [Color(hex: "#9333EA") ?? .purple, Color(hex: "#3B82F6") ?? .blue],
            prompt: "Собери атмосферный ночной плейлист из 50 треков: Synthwave, Retrowave, Darksynth и Midnight Electronic для ночных поездок."
        ),
        VibePreset(
            title: "Инди под дождь",
            subtitle: "Уютная меланхолия",
            icon: "cloud.rain.fill",
            gradient: [Color(hex: "#06B6D4") ?? .cyan, Color(hex: "#6366F1") ?? .indigo],
            prompt: "Собери меланхоличный и душевный плейлист из 50 треков в стилях Indie Pop, Indie Rock и Dream Pop для дождливого вечера."
        ),
        VibePreset(
            title: "Lo-Fi Концентрация",
            subtitle: "Фокус, кофе и чилл",
            icon: "cup.and.saucer.fill",
            gradient: [Color(hex: "#F59E0B") ?? .orange, Color(hex: "#10B981") ?? .green],
            prompt: "Составь спокойный чилловый инструментальный плейлист из 50 треков: Lo-Fi Hip-Hop, Jazzhop и Chillhop для работы и учебы."
        ),
        VibePreset(
            title: "Тек-хаус Драйв",
            subtitle: "Клубный грув 128 BPM",
            icon: "bolt.fill",
            gradient: [Color(hex: "#EC4899") ?? .pink, Color(hex: "#8B5CF6") ?? .purple],
            prompt: "Собери клубный танцевальный плейлист из 50 треков: Tech House, Bass House и Deep House с плотным грувом."
        ),
        VibePreset(
            title: "Космический Эмбиент",
            subtitle: "Глубокое погружение",
            icon: "sparkles",
            gradient: [Color(hex: "#3B82F6") ?? .blue, Color(hex: "#10B981") ?? .teal],
            prompt: "Составь медитативный атмосферный плейлист из 50 треков: Space Ambient, Cinematic Neoclassical и Drone без слов."
        )
    ]

    // MARK: - Clarification Categories
    enum ClarifyCategory: String, CaseIterable, Identifiable {
        case language = "Язык"
        case mood = "Вайб"
        case era = "Эпоха"
        case questions = "Вопросы"

        var id: String { rawValue }

        var options: [String] {
            switch self {
            case .language:
                return ["🇷🇺 Только на русском", "🇺🇸 Англоязычные треки", "🎹 Без слов / Инструментал", "🌍 Любой язык"]
            case .mood:
                return ["⚡ Максимальный кач и энергия", "☕ Спокойный chill / релакс", "💔 Грустная меланхолия", "🚗 Драйв для ночного авто"]
            case .era:
                return ["✨ Свежие новинки 2026", "💿 Золотая эра 2000-х", "📼 Винтаж 80-е и 90-е"]
            case .questions:
                return ["🎯 Задай мне 3 вопроса для точного подбора", "🔍 Подбери похожие на мой текущий трек", "🎲 Случайный концептуальный микс"]
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background & Dynamic Aura Glow
                ambientBackground

                VStack(spacing: 0) {
                    messagesScrollView
                    inputBottomBar
                }

                // Toast Notification Overlay
                if let toast = store.copiedToastMessage {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(SN.positive)
                            Text(toast)
                                .font(SN.text(.subheadline, .semibold))
                                .foregroundStyle(SN.ink)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassCapsule(interactive: false)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))

                        Spacer()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    GlassIconButton(
                        systemImage: "xmark",
                        tint: SN.ink,
                        accessibilityLabel: "Закрыть ассистент"
                    ) {
                        store.savePersistedState()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .principal) {
                    headerModelSelectorButton
                }

                ToolbarItem(placement: .topBarTrailing) {
                    headerTrailingButtons
                }
            }
            .sheet(isPresented: $showSettings) {
                DifySettingsSheet()
            }
            .alert("Очистить диалог?", isPresented: $showClearAlert) {
                Button("Очистить", role: .destructive) {
                    Haptics.notification(.warning)
                    store.clearChat()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("История генераций и подборок будет удалена из текущей сессии ассистента.")
            }
        }
    }

    // MARK: - Ambient Background
    private var ambientBackground: some View {
        ZStack {
            SN.bg.ignoresSafeArea()

            // Dynamic glow reflecting active provider
            let primaryColor = dify.provider == .nvidia
                ? (Color(hex: "#76B900") ?? .green)
                : (Color(hex: "#9333EA") ?? .purple)

            RadialGradient(
                colors: [
                    primaryColor.opacity(0.18),
                    Color.cyan.opacity(0.08),
                    Color.clear
                ],
                center: .top,
                startRadius: 10,
                endRadius: 460
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Header Model Selector
    private var headerModelSelectorButton: some View {
        Button {
            Haptics.tap(.light)
            showSettings = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(dify.isConfigured ? SN.positive : .orange)
                    .frame(width: 7, height: 7)
                    .shadow(color: (dify.isConfigured ? SN.positive : .orange).opacity(0.6), radius: 4)

                VStack(alignment: .leading, spacing: 1) {
                    Text(dify.provider == .nvidia ? "NVIDIA NIM" : "AI Студия")
                        .font(SN.display(.caption2, .bold))
                        .foregroundStyle(SN.ink)

                    Text(dify.activeModelDisplayName)
                        .font(SN.text(.caption2, .medium))
                        .foregroundStyle(SN.inkMuted)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SN.inkMuted)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var headerTrailingButtons: some View {
        HStack(spacing: 8) {
            if !store.messages.isEmpty {
                GlassIconButton(
                    systemImage: "trash",
                    tint: SN.inkMuted,
                    accessibilityLabel: "Очистить диалог"
                ) {
                    showClearAlert = true
                }
            }

            GlassIconButton(
                systemImage: "slider.horizontal.3",
                tint: SN.accent,
                accessibilityLabel: "Настройки модели"
            ) {
                showSettings = true
            }
        }
    }

    // MARK: - Messages ScrollView
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    if store.messages.isEmpty {
                        modernStudioWelcomeHero
                    } else {
                        ForEach(store.messages) { msg in
                            messageRow(msg)
                                .id(msg.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: store.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: store.messages.last?.text) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    // MARK: - Modern Studio Welcome Hero
    private var modernStudioWelcomeHero: some View {
        VStack(spacing: 22) {
            // Visual Studio Header Card
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    (dify.provider == .nvidia ? (Color(hex: "#76B900") ?? .green) : Color.purple).opacity(0.4),
                                    Color.cyan.opacity(0.12),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 5,
                                endRadius: 75
                            )
                        )
                        .frame(width: 110, height: 110)

                    Image(systemName: "sparkles")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    dify.provider == .nvidia ? (Color(hex: "#76B900") ?? .green) : Color.pink,
                                    Color.purple,
                                    Color.cyan
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .glassEffect(.regular, in: .circle)
                        .frame(width: 72, height: 72)
                }

                VStack(spacing: 6) {
                    Text("AI-Куратор Sonivo")
                        .font(SN.display(.title2, .bold))
                        .foregroundStyle(SN.ink)

                    Text("Интеллектуальная студия генерации плейлистов от 50 треков на базе нейросетей сентября 2026. Опишите желаемый вайб или выберите пресет.")
                        .font(SN.text(.subheadline))
                        .foregroundStyle(SN.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                if !dify.isConfigured {
                    Button {
                        Haptics.tap(.light)
                        showSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                            Text("Указать API-ключ для активации")
                        }
                        .font(SN.text(.caption, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassProminent(SN.amber)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 16)

            // Vibe Presets Grid (2 Columns, Rich Cards)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("ВЫБЕРИТЕ ВАЙБ")
                        .font(SN.display(.caption, .bold))
                        .foregroundStyle(SN.inkFaint)
                        .tracking(1)

                    Spacer()

                    Text("от 50 треков")
                        .font(SN.text(.caption2, .semibold))
                        .foregroundStyle(SN.amber)
                }
                .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(vibePresets) { preset in
                        Button {
                            Haptics.tap(.medium)
                            send(preset.prompt)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    ZStack {
                                        LinearGradient(
                                            colors: preset.gradient,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                        Image(systemName: preset.icon)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    Spacer()

                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(SN.inkFaint)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title)
                                        .font(SN.rounded(.subheadline, .bold))
                                        .foregroundStyle(SN.ink)
                                        .lineLimit(1)

                                    Text(preset.subtitle)
                                        .font(SN.text(.caption2))
                                        .foregroundStyle(SN.inkMuted)
                                        .lineLimit(1)
                                }
                            }
                            .padding(12)
                            .glassCard(corner: 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 30)
        }
    }

    // MARK: - Message Row
    @ViewBuilder
    private func messageRow(_ msg: AIMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 44)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(msg.text)
                        .font(SN.text(.body))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [SN.amber, SN.flame],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: SN.flame.opacity(0.25), radius: 8, y: 3)

                    Button {
                        store.copyToClipboard(msg.text, notice: "Запрос скопирован")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text("Копировать")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SN.inkFaint)
                        .padding(.trailing, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                // Curator Avatar
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    dify.provider == .nvidia ? (Color(hex: "#76B900") ?? .green) : Color.purple,
                                    Color.cyan
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)

                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 14) {
                    // Clean Human Editorial Text (Never Raw JSON!)
                    let cleanedText = DifyService.cleanDisplayText(from: msg.text)
                    if !cleanedText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(cleanedText)
                                .font(SN.text(.body))
                                .foregroundStyle(SN.ink)
                                .lineSpacing(3)

                            Button {
                                store.copyToClipboard(cleanedText, notice: "Ответ скопирован")
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                    Text("Скопировать текст")
                                }
                                .font(SN.text(.caption2, .semibold))
                                .foregroundStyle(SN.inkMuted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassCapsule(interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                    } else if !msg.isStreaming && msg.playlist != nil {
                        Text("Вот эксклюзивная подборка треков по вашему настроению:")
                            .font(SN.text(.body))
                            .foregroundStyle(SN.ink)
                    }

                    // Live Generation / Streaming Indicator
                    if msg.isStreaming {
                        HStack(spacing: 10) {
                            VibeEqualizerWaveView(isActive: true)
                            Text(cleanedText.isEmpty ? "AI подбирает 50 треков под ваш вайб…" : "Формирую концепцию плейлиста…")
                                .font(SN.text(.subheadline, .medium))
                                .foregroundStyle(SN.inkMuted)
                        }
                        .padding(.vertical, 6)
                    }

                    // Playlist Showcase Card
                    if let playlist = msg.playlist {
                        modernPlaylistShowcaseCard(playlist: playlist, msg: msg)
                    }

                    if let err = msg.error {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(err).font(SN.text(.footnote)).foregroundStyle(.red)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .glassCard(corner: 20)

                Spacer(minLength: 20)
            }
        }
    }

    // MARK: - Modern Playlist Showcase Card
    private func modernPlaylistShowcaseCard(playlist: AIGeneratedPlaylist, msg: AIMessage) -> some View {
        let isExpanded = expandedPlaylistMessages.contains(msg.id)
        let displayTracks = msg.resolvedTracks
        let trackCount = !displayTracks.isEmpty ? displayTracks.count : playlist.tracks.count

        return VStack(alignment: .leading, spacing: 14) {
            // Header: Big Cover Art & Title Info
            HStack(alignment: .center, spacing: 12) {
                // High-resolution Artwork Preview
                if let firstTrack = displayTracks.first(where: { $0.coverURL != nil && !($0.coverURL?.isEmpty ?? true) }),
                   let cover = firstTrack.coverURL,
                   let url = URL(string: cover) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            fallbackPlaylistGradient
                        }
                    }
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                } else {
                    fallbackPlaylistGradient
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.playlistTitle)
                        .font(SN.display(.headline, .bold))
                        .foregroundStyle(SN.ink)
                        .lineLimit(2)

                    Text(playlist.description)
                        .font(SN.text(.caption))
                        .foregroundStyle(SN.inkMuted)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SN.amber)

                        Text("\(trackCount) треков • AI Куратор")
                            .font(SN.text(.caption2, .bold))
                            .foregroundStyle(SN.amber)
                    }
                    .padding(.top, 2)
                }

                Spacer()
            }

            Divider().overlay(SN.ink.opacity(0.12))

            // Resolving Tracks Progress
            if msg.isResolvingTracks {
                HStack(spacing: 10) {
                    ProgressView().tint(SN.ink)
                    Text("Мгновенный поиск треков в каталоге Sonivo…")
                        .font(SN.text(.subheadline))
                        .foregroundStyle(SN.inkMuted)
                }
                .padding(.vertical, 6)
            } else if !displayTracks.isEmpty {
                // Track list preview
                let itemsToShow = isExpanded ? displayTracks : Array(displayTracks.prefix(7))
                VStack(spacing: 6) {
                    ForEach(Array(itemsToShow.enumerated()), id: \.element.id) { index, track in
                        trackRow(track: track, index: index + 1, allTracks: displayTracks)
                    }

                    if displayTracks.count > 7 {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                if isExpanded {
                                    expandedPlaylistMessages.remove(msg.id)
                                } else {
                                    expandedPlaylistMessages.insert(msg.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(isExpanded ? "Свернуть список" : "Показать все \(displayTracks.count) треков")
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            }
                            .font(SN.text(.caption, .bold))
                            .foregroundStyle(settings.accentColor)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Action Buttons Row: Play, Add to Collection, +50
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        // Play Button
                        Button {
                            Haptics.tap(.heavy)
                            AIPlaylistGeneratorService.shared.playNow(tracks: displayTracks)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("Слушать")
                            }
                            .font(SN.text(.subheadline, .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .glassProminent(SN.amber)
                        }
                        .buttonStyle(.plain)

                        // Save to Collection Button
                        let isSaved = store.savedPlaylistTitles.contains(playlist.playlistTitle)
                        Button {
                            guard !isSaved else { return }
                            Haptics.tap(.medium)
                            AIPlaylistGeneratorService.shared.saveToLibrary(playlist: playlist, tracks: displayTracks)
                            store.savedPlaylistTitles.insert(playlist.playlistTitle)
                            store.savePersistedState()
                            store.copyToClipboard("", notice: "Плейлист «\(playlist.playlistTitle)» добавлен в коллекцию!")
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isSaved ? "checkmark" : "plus.rectangle.on.folder")
                                Text(isSaved ? "В коллекции" : "В коллекцию")
                            }
                            .font(SN.text(.subheadline, .semibold))
                            .foregroundStyle(isSaved ? SN.positive : SN.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .glassCapsule(interactive: true)
                        }
                        .buttonStyle(.plain)

                        // +50 More Button (Required by test and user)
                        Button {
                            extendPlaylistBy50(msg: msg)
                        } label: {
                            HStack(spacing: 5) {
                                if extendingMessageId == msg.id {
                                    ProgressView().tint(SN.ink).scaleEffect(0.8)
                                    Text("…")
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(SN.amber)
                                    Text("+50 ещё")
                                }
                            }
                            .font(SN.text(.subheadline, .semibold))
                            .foregroundStyle(SN.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .glassCapsule(interactive: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(extendingMessageId == msg.id)
                    }

                    // Copy Playlist Tracklist Action
                    Button {
                        let text = displayTracks.enumerated().map { "\($0.offset + 1). \($0.element.artist) — \($0.element.title)" }.joined(separator: "\n")
                        store.copyToClipboard("Плейлист: \(playlist.playlistTitle)\n\n" + text, notice: "Список \(displayTracks.count) треков скопирован")
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("Скопировать список треков")
                        }
                        .font(SN.text(.caption2, .medium))
                        .foregroundStyle(SN.inkMuted)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            } else {
                // Fallback text suggestions
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(playlist.tracks) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .font(.system(size: 11))
                                .foregroundStyle(SN.inkMuted)
                            Text("\(item.artist) — \(item.title)")
                                .font(SN.text(.subheadline))
                                .foregroundStyle(SN.ink)
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassCard(corner: 18)
    }

    private var fallbackPlaylistGradient: some View {
        ZStack {
            LinearGradient(
                colors: [SN.amber, Color(hex: "#9333EA") ?? .purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note.list")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Track Row Component
    private func trackRow(track: Track, index: Int, allTracks: [Track]) -> some View {
        Button {
            Haptics.tap(.light)
            PlaybackCommandRouter.shared.play(track, queue: allTracks)
        } label: {
            HStack(spacing: 10) {
                Text("\(index)")
                    .font(SN.text(.caption2, .semibold).monospacedDigit())
                    .foregroundStyle(SN.inkFaint)
                    .frame(width: 20, alignment: .trailing)

                SmallArtwork(track: track, size: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(SN.rounded(.subheadline, .medium))
                        .foregroundStyle(player.currentTrack?.id == track.id ? settings.accentColor : SN.ink)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(SN.text(.caption2))
                        .foregroundStyle(SN.inkMuted)
                        .lineLimit(1)
                }

                Spacer()

                if player.currentTrack?.id == track.id {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(settings.accentColor)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(SN.amber.opacity(0.85))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Bottom Bar
    private var inputBottomBar: some View {
        VStack(spacing: 8) {
            // Clarifying precision chips
            clarifyingFilterBar

            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundStyle(SN.amber)

                    TextField("Опишите настроение или стиль...", text: $inputText)
                        .focused($isInputFocused)
                        .font(SN.text(.body))
                        .foregroundStyle(SN.ink)
                        .onSubmit {
                            submitCurrentText()
                        }

                    if !inputText.isEmpty {
                        Button {
                            inputText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(SN.inkFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .glassCapsule(interactive: true)

                // Send Button with animated gradient
                Button {
                    submitCurrentText()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                isSendDisabled
                                    ? LinearGradient(colors: [Color.white.opacity(0.1), Color.white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    : SN.emberGradient
                            )
                            .frame(width: 44, height: 44)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(isSendDisabled ? SN.inkFaint : .white)
                    }
                    .glassCircle(interactive: !isSendDisabled)
                }
                .disabled(isSendDisabled)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 4)
        }
        .background(
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 0))
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Clarifying Filter Bar
    private var clarifyingFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClarifyCategory.allCases) { cat in
                        Button {
                            Haptics.tap(.light)
                            withAnimation(.spring(response: 0.25)) {
                                if selectedFilterCategory == cat {
                                    selectedFilterCategory = nil
                                } else {
                                    selectedFilterCategory = cat
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(cat.rawValue)
                                    .font(SN.text(.caption, .semibold))
                                Image(systemName: selectedFilterCategory == cat ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(selectedFilterCategory == cat ? .white : SN.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedFilterCategory == cat ? SN.amber : Color.clear)
                            .glassCapsule(interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            if let cat = selectedFilterCategory {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cat.options, id: \.self) { opt in
                            Button {
                                Haptics.tap(.light)
                                withAnimation(.spring(response: 0.25)) {
                                    selectedFilterCategory = nil
                                }
                                if opt.contains("3 вопроса") {
                                    send("Задай мне 3 коротких вопроса о моих предпочтениях (язык, жанр, темп), чтобы составить идеальный плейлист из 50 треков.")
                                } else {
                                    let query = inputText.isEmpty ? "Собери плейлист из 50 треков: \(opt)" : "\(inputText) (\(opt))"
                                    inputText = ""
                                    send(query)
                                }
                            } label: {
                                Text(opt)
                                    .font(SN.text(.caption2, .medium))
                                    .foregroundStyle(SN.ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .glassCard(corner: 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var isSendDisabled: Bool {
        isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitCurrentText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        send(text)
    }

    // MARK: - Send Action
    private func send(_ prompt: String) {
        guard !isSending else { return }

        if !dify.isConfigured {
            showSettings = true
            return
        }

        Haptics.tap(.light)
        isInputFocused = false
        isSending = true

        let userMsg = AIMessage(role: .user, text: prompt)
        store.messages.append(userMsg)
        store.savePersistedState()

        let assistantMsgId = UUID()
        let assistantMsg = AIMessage(
            id: assistantMsgId,
            role: .assistant,
            text: "",
            isStreaming: true
        )
        store.messages.append(assistantMsg)

        Task {
            do {
                let (_, _, playlist) = try await dify.sendMessage(query: prompt) { delta in
                    if let idx = store.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        store.messages[idx].text += delta
                    }
                }

                if let idx = store.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                    store.messages[idx].isStreaming = false
                    store.messages[idx].playlist = playlist

                    // Ensure cleaned editorial text is saved without raw JSON
                    let clean = DifyService.cleanDisplayText(from: store.messages[idx].text)
                    if !clean.isEmpty {
                        store.messages[idx].text = clean
                    }

                    if let playlist = playlist, !playlist.tracks.isEmpty {
                        store.messages[idx].isResolvingTracks = true
                        let resolved = await AIPlaylistGeneratorService.shared.resolveTracks(for: playlist.tracks)
                        store.messages[idx].resolvedTracks = resolved
                        store.messages[idx].isResolvingTracks = false
                    }
                }

                store.savePersistedState()

                await MainActor.run {
                    isSending = false
                }
            } catch {
                if let idx = store.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                    store.messages[idx].isStreaming = false
                    store.messages[idx].error = error.localizedDescription
                }
                store.savePersistedState()
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }

    // MARK: - Extend Playlist (+50)
    func extendPlaylistBy50(msg: AIMessage) {
        guard extendingMessageId == nil else { return }
        guard let playlist = msg.playlist else { return }
        Haptics.tap(.medium)
        extendingMessageId = msg.id

        Task {
            do {
                let newTracks = try await AIPlaylistGeneratorService.shared.extendPlaylist(
                    playlistTitle: playlist.playlistTitle,
                    description: playlist.description,
                    existingTracks: msg.resolvedTracks
                )

                if let idx = store.messages.firstIndex(where: { $0.id == msg.id }) {
                    store.messages[idx].resolvedTracks.append(contentsOf: newTracks)
                    let newSuggestions = newTracks.map { AITrackSuggestion(artist: $0.artist, title: $0.title) }
                    store.messages[idx].playlist?.tracks.append(contentsOf: newSuggestions)

                    // If already saved in library, update library playlist too!
                    if let libPlaylist = LibraryStore.shared.playlists.first(where: { $0.title == playlist.playlistTitle }) {
                        LibraryStore.shared.addTracksToPlaylist(tracks: newTracks, playlistId: libPlaylist.id)
                    }

                    store.savePersistedState()
                    store.copyToClipboard("", notice: "Добавлено +\(newTracks.count) треков в подборку!")
                    Haptics.notification(.success)
                }
            } catch {
                store.copyToClipboard("", notice: "Ошибка: \(error.localizedDescription)")
            }

            await MainActor.run {
                extendingMessageId = nil
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = store.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}

// MARK: - Live Vibe Equalizer Wave Visualizer

private struct VibeEqualizerWaveView: View {
    let isActive: Bool
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { barIndex in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let height = isActive
                        ? 6 + 12 * abs(sin(time * 6.0 + Double(barIndex) * 0.9))
                        : 6.0

                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [SN.amber, SN.flame],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 20)
        }
    }
}
