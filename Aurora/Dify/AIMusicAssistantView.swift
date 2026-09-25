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
                // Background dark gradient
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.05, blue: 0.16),
                        Color(red: 0.04, green: 0.04, blue: 0.08),
                        Color.black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
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
                    Button {
                        Haptics.tap(.light)
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Text("AI Куратор")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)

                            Text("2026")
                                .font(.system(size: 10, weight: .black))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .leading, endPoint: .trailing)
                                )
                                .clipShape(Capsule())
                                .foregroundStyle(.white)
                        }

                        Text(dify.isConfigured ? "Dify Cloud • Готов к работе" : "Требуется API-ключ")
                            .font(.system(size: 11))
                            .foregroundStyle(dify.isConfigured ? .green.opacity(0.85) : .orange)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if !messages.isEmpty {
                            Button {
                                Haptics.tap(.light)
                                clearChat()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }

                        Button {
                            Haptics.tap(.light)
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.white.opacity(0.8))
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
                    .fill(RadialGradient(
                        colors: [Color.purple.opacity(0.6), Color.blue.opacity(0.2), Color.clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 80
                    ))
                    .frame(width: 140, height: 140)

                Image(systemName: "sparkles")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(hex: "#FF455B") ?? .pink, Color(hex: "#9333EA") ?? .purple, Color.cyan],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }

            VStack(spacing: 8) {
                Text("Музыкальный AI-ассистент")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Text("Попроси собрать подборку под любое настроение, тренировку или жанр. Я найду треки в каталоге и создам готовый плейлист.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
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
                        Text("Настроить API-ключ Dify")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.purple.opacity(0.7))
                    .clipShape(Capsule())
                }
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("ПОПУЛЯРНЫЕ ЗАПРОСЫ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.leading, 8)

                ForEach(quickPrompts, id: \.self) { prompt in
                    Button {
                        Haptics.tap(.light)
                        send(prompt)
                    } label: {
                        HStack {
                            Text(prompt)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .padding(.top, 10)

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
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.85), Color.indigo.opacity(0.9)],
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
                        .fill(LinearGradient(colors: [Color.purple, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 12) {
                    let cleanedText = DifyService.cleanDisplayText(from: msg.text)
                    if !cleanedText.isEmpty {
                        Text(cleanedText)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineSpacing(3)
                    }

                    if msg.isStreaming && msg.text.isEmpty {
                        HStack(spacing: 4) {
                            Circle().fill(Color.purple).frame(width: 6, height: 6)
                            Circle().fill(Color.cyan).frame(width: 6, height: 6)
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
                            Text(err).font(.system(size: 13)).foregroundStyle(.red)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

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
                        colors: [Color(hex: "#FF455B") ?? .pink, Color(hex: "#9333EA") ?? .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.playlistTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)

                    Text(playlist.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
            }

            Divider().background(Color.white.opacity(0.15))

            if msg.isResolvingTracks {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Поиск треков в Яндекс Музыке...")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.vertical, 8)
            } else if !msg.resolvedTracks.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(msg.resolvedTracks.prefix(8))) { track in
                        trackRow(track: track, allTracks: msg.resolvedTracks)
                    }

                    if msg.resolvedTracks.count > 8 {
                        Text("И ещё \(msg.resolvedTracks.count - 8) треков...")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
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
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSaved ? .green : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.top, 4)
            } else {
                // If resolving returned no playable tracks, show suggestions list
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(playlist.tracks) { item in
                        HStack {
                            Image(systemName: "music.note")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("\(item.artist) — \(item.title)")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    ZStack {
                        Color.purple.opacity(0.3)
                        Image(systemName: "music.note")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "play.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Bottom Bar
    private var inputBottomBar: some View {
        VStack(spacing: 8) {
            // Horizontal quick chips if text is empty
            if inputText.isEmpty && !messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPrompts, id: \.self) { prompt in
                            Button {
                                Haptics.tap(.light)
                                send(prompt)
                            } label: {
                                Text(prompt)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.08))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(spacing: 10) {
                TextField("Попроси создать плейлист...", text: $inputText)
                    .focused($isInputFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.09))
                    .clipShape(Capsule())
                    .foregroundStyle(.white)
                    .onSubmit {
                        submitCurrentText()
                    }

                Button {
                    submitCurrentText()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: isSendDisabled ? [Color.white.opacity(0.1), Color.white.opacity(0.1)] : [Color.pink, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(isSendDisabled ? .white.opacity(0.3) : .white)
                    }
                }
                .disabled(isSendDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 4)
        }
        .background(
            Color.black.opacity(0.85)
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

                    // Resolve tracks from Yandex Music API
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
