import Foundation
import UIKit
import Combine

@MainActor
final class AIMusicCuratorStore: ObservableObject {
    static let shared = AIMusicCuratorStore()
    enum Phase: Equatable {
        case idle, thinking, resolving, extending
        var title: String {
            switch self {
            case .idle: "Готов к новым открытиям"
            case .thinking: "Ищу музыкальную идею…"
            case .resolving: "Проверяю песни в каталоге…"
            case .extending: "Ищу продолжение без повторов…"
            }
        }
    }
    @Published private(set) var messages: [AIMessage] = []
    @Published private(set) var phase: Phase = .idle
    @Published var copiedToastMessage: String?
    private var operation: Task<Void, Never>?
    private var requestID = UUID()
    private var scope = ""
    var isBusy: Bool { phase != .idle }
    private let ai: DifyService
    init(ai: DifyService = .shared) { self.ai = ai; switchAccount() }
    private var defaultsKey: String { "sonivo.ai_curator.messages.v2." + scope }

    func switchAccount() {
        let next = YandexMusicService.shared.currentUser.map { String($0.uid) } ?? "local"
        guard next != scope else { return }
        cancel(); scope = next; messages = []
        ai.resetConversation()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([AIMessage].self, from: data) {
            messages = Array(decoded.suffix(AICuratorPolicy.messageLimit)).map {
                var copy = $0; copy.isStreaming = false; copy.isResolvingTracks = false; return copy
            }
        }
    }
    func savePersistedState() {
        if let data = try? JSONEncoder().encode(Array(messages.suffix(AICuratorPolicy.messageLimit))) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
    private func update(_ id: UUID, _ body: (inout AIMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        body(&messages[index])
    }
    func cancel() {
        operation?.cancel(); operation = nil; requestID = UUID(); phase = .idle
        for index in messages.indices {
            if messages[index].isStreaming || messages[index].isResolvingTracks {
                messages[index].isStreaming = false; messages[index].isResolvingTracks = false
                messages[index].error = "Остановлено. Можно уточнить запрос и попробовать снова."
            }
        }
        if !scope.isEmpty { savePersistedState() }
    }
    func clearChat() {
        cancel(); messages = []; UserDefaults.standard.removeObject(forKey: defaultsKey)
        ai.resetConversation()
    }
    private func historyContent(_ message: AIMessage) -> String {
        var text = DifyService.cleanDisplayText(from: message.text)
        if let summary = message.requestSummary { text += "\n" + summary }
        if let question = message.clarification { text += "\n" + question }
        if let playlist = message.playlist {
            text += "\nПредложенные песни: " + playlist.tracks.prefix(20).map { $0.artist + " — " + $0.title }.joined(separator: "; ")
        }
        return text
    }
    @discardableResult
    func send(_ prompt: String, shareCurrentTrack: Bool) -> Bool {
        let text = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !isBusy, !text.isEmpty, ai.isConfigured else { return false }
        switchAccount()
        let history = messages.suffix(12).filter { $0.error == nil }.map {
            OpenAIChatRequest.Message(role: $0.role.rawValue, content: String(historyContent($0).prefix(1600)))
        }
        let track = PlayerCore.shared.currentTrack
        let context = AICuratorPolicy.context(title: track?.title, artist: track?.artist, enabled: shareCurrentTrack)
        let id = UUID(), token = UUID(), account = YandexMusicService.shared.accountGeneration
        requestID = token
        messages.append(AIMessage(role: .user, text: text + context))
        messages.append(AIMessage(id: id, role: .assistant, text: "", isStreaming: true))
        if messages.count > AICuratorPolicy.messageLimit { messages.removeFirst(messages.count - AICuratorPolicy.messageLimit) }
        phase = .thinking
        operation = Task { [weak self] in
            guard let self else { return }
            var accumulated = "", lastUpdate = Date.distantPast
            do {
                let result = try await ai.sendMessage(query: text + context, history: history) { [weak self] delta in
                    accumulated += delta
                    if Date().timeIntervalSince(lastUpdate) >= 0.08 {
                        lastUpdate = Date()
                        guard let self, self.requestID == token else { return }
                        self.update(id) { $0.text = accumulated }
                    }
                }
                try Task.checkCancellation()
                guard requestID == token, account == YandexMusicService.shared.accountGeneration else { return }
                var playlistResult = result.playlist
                if playlistResult != nil { playlistResult!.tracks = Array(playlistResult!.tracks.prefix(AICuratorPolicy.suggestionLimit)) }
                let reply = AICuratorPrompt.reply(from: result.fullText)
                update(id) { $0.text = result.fullText; $0.isStreaming = false; $0.playlist = playlistResult
                    $0.requestSummary = reply?.summary; $0.clarification = reply?.intent == .clarify ? reply?.question : nil }
                if let playlist = playlistResult {
                    phase = .resolving; update(id) { $0.isResolvingTracks = true }
                    let tracks = await AIPlaylistGeneratorService.shared.resolveTracks(for: playlist.tracks)
                    try Task.checkCancellation()
                    guard requestID == token, account == YandexMusicService.shared.accountGeneration else { return }
                    update(id) { $0.resolvedTracks = tracks; $0.isResolvingTracks = false
                        $0.unresolvedCount = max(0, playlist.tracks.count - tracks.count) }
                }
            } catch {
                guard requestID == token else { return }
                update(id) { $0.isStreaming = false; $0.isResolvingTracks = false
                    $0.error = error is CancellationError ? "Остановлено" : error.localizedDescription }
            }
            guard requestID == token else { return }
            phase = .idle; operation = nil; savePersistedState()
        }
        return true
    }
    func extend(_ messageID: UUID) {
        guard !isBusy, let message = messages.first(where: { $0.id == messageID }),
              let playlist = message.playlist, !message.resolvedTracks.isEmpty else { return }
        let token = UUID(), account = YandexMusicService.shared.accountGeneration
        requestID = token; phase = .extending
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await AIPlaylistGeneratorService.shared.extendPlaylist(playlistTitle: playlist.playlistTitle,
                    description: playlist.description, existingTracks: message.resolvedTracks)
                try Task.checkCancellation()
                guard requestID == token, account == YandexMusicService.shared.accountGeneration else { return }
                update(messageID) { $0.resolvedTracks += tracks; $0.extendedCount = ($0.extendedCount ?? 0) + tracks.count }
                if let saved = message.savedPlaylistID, LibraryStore.shared.playlist(byId: saved) != nil {
                    LibraryStore.shared.addTracksToPlaylist(tracks: tracks, playlistId: saved)
                }
                showToast(tracks.isEmpty ? "Новых точных совпадений не найдено" : "Добавлено \(tracks.count) новых песен")
            } catch {
                guard requestID == token else { return }; showToast(error.localizedDescription)
            }
            guard requestID == token else { return }
            phase = .idle; operation = nil; savePersistedState()
        }
    }
    func save(_ messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }), let playlist = message.playlist else { return }
        if let saved = message.savedPlaylistID, LibraryStore.shared.playlist(byId: saved) != nil {
            showToast("Подборка уже в медиатеке"); return
        }
        if let saved = AIPlaylistGeneratorService.shared.saveToLibrary(playlist: playlist, tracks: message.resolvedTracks) {
            update(messageID) { $0.savedPlaylistID = saved }; savePersistedState(); showToast("Сохранено в медиатеку")
        }
    }
    func showToast(_ notice: String) { copiedToastMessage = notice }
    func copyToClipboard(_ text: String, notice: String = "Скопировано") {
        UIPasteboard.general.string = text; showToast(notice)
    }
}
