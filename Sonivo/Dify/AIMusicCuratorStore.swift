import Foundation
import UIKit
import Combine

@MainActor
final class AIMusicCuratorStore: ObservableObject {
    static let shared = AIMusicCuratorStore()
    enum Phase: Equatable {
        case idle, searching, thinking, resolving, extending
        var title: String {
            switch self {
            case .idle: "Готов к новым открытиям"
            case .searching: "Ищу музыкальные источники…"
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
    private let web: CuratorWebSearch
    private let ai: DifyService
    init(ai: DifyService = .shared, web: CuratorWebSearch = .shared) { self.ai = ai; self.web = web; switchAccount() }
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
        if let reference = message.songReference { text += AICuratorRequest.referenceContext(reference) }
        if let summary = message.requestSummary { text += "\n" + summary }
        if let question = message.clarification { text += "\n" + question }
        if let playlist = message.playlist {
            text += "\nПредложенные песни: " + playlist.tracks.prefix(20).map { $0.artist + " — " + $0.title }.joined(separator: "; ")
        }
        return text
    }
    @discardableResult
    func send(_ prompt: String, shareCurrentTrack: Bool, reference: CuratorSongReference? = nil) -> Bool {
        let text = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !isBusy, !text.isEmpty, ai.isConfigured else { return false }
        switchAccount()
        let history = messages.suffix(12).filter { $0.error == nil }.map {
            OpenAIChatRequest.Message(role: $0.role.rawValue, content: String(historyContent($0).prefix(1600)))
        }
        let track = PlayerCore.shared.currentTrack
        let context = reference.map(AICuratorRequest.referenceContext) ?? AICuratorPolicy.context(title: track?.title, artist: track?.artist, enabled: shareCurrentTrack)
        let yearRange = AICuratorRequest.yearRange(query:text,previousUserQueries:messages.filter { $0.role == .user }.map(\.text))
        let periodContext = AICuratorRequest.periodContext(yearRange)
        let id = UUID(), token = UUID(), account = YandexMusicService.shared.accountGeneration
        requestID = token
        var userMessage = AIMessage(role:.user,text:text + (reference == nil ? context : ""))
        userMessage.songReference = reference; userMessage.requestedYearRange = yearRange
        messages.append(userMessage)
        var answerMessage = AIMessage(id:id,role:.assistant,text:"",isStreaming:true)
        answerMessage.requestedYearRange = yearRange
        messages.append(answerMessage)
        if messages.count > AICuratorPolicy.messageLimit { messages.removeFirst(messages.count - AICuratorPolicy.messageLimit) }
        phase = web.enabled ? .searching : .thinking
        operation = Task { [weak self] in
            guard let self else { return }
            var accumulated = "", lastUpdate = Date.distantPast
            do {
                let previous = history.last(where: { $0.role == "user" }).map { String($0.content.prefix(150)) } ?? ""
                let searchReference = reference.map { "\nРеференс: " + String($0.artist.prefix(150)) + " — " + String($0.title.prefix(150)) } ?? String(context.prefix(100))
                let searchQuery = String(text.prefix(500)) + searchReference + (previous.isEmpty ? "" : "\nПредыдущее уточнение: " + previous)
                let retrieval = try await webContext(for: searchQuery, messageID: id, token: token, account: account)
                try Task.checkCancellation()
                guard requestID == token, account == YandexMusicService.shared.accountGeneration else { throw CancellationError() }
                phase = .thinking
                let result = try await ai.sendMessage(query: text + context + periodContext + retrieval, history: history) { [weak self] delta in
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
                    let tracks = await AIPlaylistGeneratorService.shared.resolveTracks(for: playlist.tracks, yearRange: yearRange)
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
    private func webContext(for query: String, messageID: UUID, token: UUID, account: UUID, isExtension: Bool = false) async throws -> String {
        guard web.enabled else { return "" }
        do {
            let result = try await web.search(query)
            try Task.checkCancellation()
            guard requestID == token, account == YandexMusicService.shared.accountGeneration else { throw CancellationError() }
            let notice = result.sources.isEmpty ? "Веб-поиск не нашёл источников. Ответ без свежих веб-данных." : nil
            update(messageID) {
                if isExtension { $0.extensionWebSources = result.sources; $0.extensionWebFetchedAt = Date(); $0.extensionWebNotice = notice }
                else { $0.webSources = result.sources; $0.webFetchedAt = Date(); $0.webNotice = notice }
            }
            return result.promptContext
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            guard requestID == token, account == YandexMusicService.shared.accountGeneration else { throw CancellationError() }
            update(messageID) {
                let notice = error.localizedDescription + " Ответ без свежих веб-данных."
                if isExtension { $0.extensionWebSources = nil; $0.extensionWebFetchedAt = nil; $0.extensionWebNotice = notice }
                else { $0.webSources = nil; $0.webFetchedAt = nil; $0.webNotice = notice }
            }
            return ""
        }
    }
    func extend(_ messageID: UUID) {
        guard !isBusy, let message = messages.first(where: { $0.id == messageID }),
              let playlist = message.playlist, !message.resolvedTracks.isEmpty else { return }
        let token = UUID(), account = YandexMusicService.shared.accountGeneration
        requestID = token; phase = .extending
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await webContext(for: "Новые песни для подборки: " + playlist.playlistTitle + ". " + playlist.description,
                                                   messageID: messageID, token: token, account: account, isExtension: true)
                try Task.checkCancellation()
                guard requestID == token, account == YandexMusicService.shared.accountGeneration else { throw CancellationError() }
                let tracks = try await AIPlaylistGeneratorService.shared.extendPlaylist(playlistTitle: playlist.playlistTitle,
                    description: playlist.description, existingTracks: message.resolvedTracks, webContext: context, yearRange: message.requestedYearRange)
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
