import SwiftUI

struct AIMusicAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dify = DifyService.shared

    @State private var messages: [AIMessage] = []
    @State private var inputText: String = ""
    @State private var isSending = false
    @State private var showSettings = false
    @State private var savedPlaylistTitles: Set<String> = []
    @FocusState private var isInputFocused: Bool

    private let quickPrompts = [
        "🔥 Фонк для тренировки в зале",
        "🌃 Ночной синтвейв и ретровейв",
        "🌧️ Меланхоличный инди-рок под дождь",
        "⚡ Энергичный тек-хаус для вечеринки",
        "☕ Спокойный лоу-фай для концентрации",
        "🌌 Космический эмбиент без слов"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                // Liquid Glass native ambient background
                AG.bg.ignoresSafeArea()

                // Subtle atmospheric backdrop glow
                RadialGradient(
                    colors: [
                        (Color(hex: "#76B900") ?? .green).opacity(dify.provider == .nvidia ? 0.15 : 0.0),
                        Color.purple.opacity(0.12),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 20,
                    endRadius: 400
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    messagesScrollView
                    inputBottomBar
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    GlassIconButton(
                        systemImage: "xmark",
                        tint: AG.ink,
                        accessibilityLabel: "Закрыть ассистент"
                    ) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .principal) {
                    Button {
                        Haptics.tap(.light)
                        showSettings = true
                    } label: {
                        VStack(spacing: 2) {
                            Text("AI Куратор")
                                .font(AG.text(.subheadline, .bold))
                                .foregroundStyle(AG.ink)

                            HStack(spacing: 5) {
                                Circle()
                                    .fill(dify.isConfigured ? AG.positive : .orange)
                                    .frame(width: 6, height: 6)

                                Text(dify.activeModelDisplayName)
                                    .font(AG.text(.caption2, .semibold))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(1)

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(AG.inkMuted)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .glassCapsule(interactive: true)
                        }
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        if !messages.isEmpty {
                            GlassIconButton(
                                systemImage: "trash",
                                tint: AG.inkMuted,
                                accessibilityLabel: "Очистить диалог"
                            ) {
                                clearChat()
                            }
                        }

                        GlassIconButton(
                            systemImage: "gearshape.fill",
                            tint: AG.accent,
                            accessibilityLabel: "Настройки"
                        ) {
                            showSettings = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                DifySettingsSheet()
            }
        }
    }

    // MARK: - Messages ScrollView
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if messages.isEmpty {
                        welcomeHero
                    } else {
                        ForEach(messages) { msg in
                            messageRow(msg)
                                .id(msg.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: messages.last?.text) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    // MARK: - Welcome Hero
    private var welcomeHero: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                (dify.provider == .nvidia ? (Color(hex: "#76B900") ?? .green) : Color.purple).opacity(0.45),
                                Color.blue.opacity(0.15),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 90
                        )
                    )
                    .frame(width: 130, height: 130)

                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [dify.provider == .nvidia ? (Color(hex: "#76B900") ?? .green) : Color.pink, Color.teal, Color.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .glassEffect(.regular, in: .circle)
                    .frame(width: 80, height: 80)
            }

            VStack(spacing: 8) {
                Text("Музыкальный AI-Куратор")
                    .font(AG.display(.title2, .bold))
                    .foregroundStyle(AG.ink)

                Text("Соберет подборку под любое настроение, тренировку или жанр на базе \(dify.activeModelDisplayName). Нажмите на быстрый запрос или напишите свой.")
                    .font(AG.text(.subheadline))
                    .foregroundStyle(AG.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if !dify.isConfigured {
                Button {
                    Haptics.tap(.light)
                    showSettings = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                        Text("Указать API-ключ")
                    }
                    .font(AG.text(.subheadline, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassProminent(AG.amber)
                }
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("БЫСТРЫЕ ВАЙБЫ")
                    .font(AG.text(.caption2, .bold))
                    .foregroundStyle(AG.inkFaint)
                    .padding(.leading, 8)

                ForEach(quickPrompts, id: \.self) { prompt in
                    Button {
                        Haptics.tap(.light)
                        send(prompt)
                    } label: {
                        HStack {
                            Text(prompt)
                                .font(AG.text(.subheadline, .medium))
                                .foregroundStyle(AG.ink)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AG.inkMuted)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glassCard(corner: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 40)
        }
    }

    // MARK: - Message Row
    @ViewBuilder
    private func messageRow(_ msg: AIMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(msg.text)
                    .font(AG.text(.body))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [AG.amber, AG.flame],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [dify.provider == .nvidia ? (Color(hex: "#76B900") ?? .green) : Color.purple, Color.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 32, height: 32)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 12) {
                    let cleanedText = DifyService.cleanDisplayText(from: msg.text)
                    if !cleanedText.isEmpty {
                        Text(cleanedText)
                            .font(AG.text(.body))
                            .foregroundStyle(AG.ink)
                            .lineSpacing(3)
                    }

                    if msg.isStreaming && msg.text.isEmpty {
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: "#76B900") ?? .green).frame(width: 6, height: 6)
                            Circle().fill(Color.teal).frame(width: 6, height: 6)
                            Circle().fill(Color.white).frame(width: 6, height: 6)
                        }
                        .padding(.vertical, 8)
                    }

                    if let playlist = msg.playlist {
                        playlistCardView(playlist: playlist, msg: msg)
                    }

                    if let err = msg.error {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(err).font(AG.text(.footnote)).foregroundStyle(.red)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .glassCard(corner: 18)

                Spacer(minLength: 24)
            }
        }
    }

    // MARK: - Playlist Card View
    private func playlistCardView(playlist: AIGeneratedPlaylist, msg: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    LinearGradient(
                        colors: [AG.amber, Color(hex: "#9333EA") ?? .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.playlistTitle)
                        .font(AG.rounded(.headline, .bold))
                        .foregroundStyle(AG.ink)

                    Text(playlist.description)
                        .font(AG.text(.caption))
                        .foregroundStyle(AG.inkMuted)
                        .lineLimit(2)
                }
            }

            Divider().overlay(AG.ink.opacity(0.12))

            if msg.isResolvingTracks {
                HStack(spacing: 8) {
                    ProgressView().tint(AG.ink)
                    Text("Поиск треков в Яндекс Музыке...")
                        .font(AG.text(.subheadline))
                        .foregroundStyle(AG.inkMuted)
                }
                .padding(.vertical, 8)
            } else if !msg.resolvedTracks.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(msg.resolvedTracks.prefix(8))) { track in
                        trackRow(track: track, allTracks: msg.resolvedTracks)
                    }

                    if msg.resolvedTracks.count > 8 {
                        Text("И ещё \(msg.resolvedTracks.count - 8) треков...")
                            .font(AG.text(.caption2))
                            .foregroundStyle(AG.inkFaint)
                            .padding(.top, 2)
                    }
                }

                // Action buttons: Play & Save
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap(.heavy)
                        AIPlaylistGeneratorService.shared.playNow(tracks: msg.resolvedTracks)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Слушать")
                        }
                        .font(AG.text(.subheadline, .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .glassProminent(AG.amber)
                    }
                    .buttonStyle(.plain)

                    let isSaved = savedPlaylistTitles.contains(playlist.playlistTitle)
                    Button {
                        guard !isSaved else { return }
                        Haptics.tap(.medium)
                        AIPlaylistGeneratorService.shared.saveToLibrary(playlist: playlist, tracks: msg.resolvedTracks)
                        savedPlaylistTitles.insert(playlist.playlistTitle)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isSaved ? "checkmark" : "plus.rectangle.on.folder")
                            Text(isSaved ? "Сохранено" : "В коллекцию")
                        }
                        .font(AG.text(.subheadline, .semibold))
                        .foregroundStyle(isSaved ? AG.positive : AG.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .glassCapsule(interactive: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(playlist.tracks) { item in
                        HStack {
                            Image(systemName: "music.note")
                                .font(.system(size: 11))
                                .foregroundStyle(AG.inkMuted)
                            Text("\(item.artist) — \(item.title)")
                                .font(AG.text(.subheadline))
                                .foregroundStyle(AG.ink)
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassCard(corner: 16)
    }

    private func trackRow(track: Track, allTracks: [Track]) -> some View {
        Button {
            Haptics.tap(.light)
            PlaybackCommandRouter.shared.play(track, queue: allTracks)
        } label: {
            HStack(spacing: 10) {
                if let cover = track.coverURL, let url = URL(string: cover) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.purple.opacity(0.3)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ZStack {
                        Color.purple.opacity(0.3)
                        Image(systemName: "music.note")
                            .font(.system(size: 12))
                            .foregroundStyle(AG.inkMuted)
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(AG.rounded(.subheadline, .medium))
                        .foregroundStyle(AG.ink)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(AG.text(.caption2))
                        .foregroundStyle(AG.inkMuted)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AG.amber)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Bottom Bar
    private var inputBottomBar: some View {
        VStack(spacing: 8) {
            if inputText.isEmpty && !messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPrompts, id: \.self) { prompt in
                            Button {
                                Haptics.tap(.light)
                                send(prompt)
                            } label: {
                                Text(prompt)
                                    .font(AG.text(.caption, .medium))
                                    .foregroundStyle(AG.ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .glassCapsule(interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(spacing: 10) {
                TextField("Спроси или опиши настроение...", text: $inputText)
                    .focused($isInputFocused)
                    .font(AG.text(.body))
                    .foregroundStyle(AG.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassCapsule(interactive: true)
                    .onSubmit {
                        submitCurrentText()
                    }

                Button {
                    submitCurrentText()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                isSendDisabled
                                    ? LinearGradient(colors: [Color.white.opacity(0.1), Color.white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    : AG.emberGradient
                            )
                            .frame(width: 44, height: 44)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(isSendDisabled ? AG.inkFaint : .white)
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
        messages.append(userMsg)

        let assistantMsgId = UUID()
        let assistantMsg = AIMessage(
            id: assistantMsgId,
            role: .assistant,
            text: "",
            isStreaming: true
        )
        messages.append(assistantMsg)

        Task {
            do {
                let (_, _, playlist) = try await dify.sendMessage(query: prompt) { delta in
                    if let idx = messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        messages[idx].text += delta
                    }
                }

                if let idx = messages.firstIndex(where: { $0.id == assistantMsgId }) {
                    messages[idx].isStreaming = false
                    messages[idx].playlist = playlist

                    if let playlist = playlist, !playlist.tracks.isEmpty {
                        messages[idx].isResolvingTracks = true
                        let resolved = await AIPlaylistGeneratorService.shared.resolveTracks(for: playlist.tracks)
                        messages[idx].resolvedTracks = resolved
                        messages[idx].isResolvingTracks = false
                    }
                }

                await MainActor.run {
                    isSending = false
                }
            } catch {
                if let idx = messages.firstIndex(where: { $0.id == assistantMsgId }) {
                    messages[idx].isStreaming = false
                    messages[idx].error = error.localizedDescription
                }
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }

    private func clearChat() {
        messages = []
        savedPlaylistTitles.removeAll()
        dify.resetConversation()
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}
