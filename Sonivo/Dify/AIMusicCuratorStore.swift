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
    @Published private(set) var catalogProgress: String?
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
        operation?.cancel(); operation = nil; requestID = UUID(); phase = .idle; catalogProgress = nil
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
        let inherited = CuratorSelectionRules.isFollowup(text) ? messages.last(where: { $0.role == .assistant && $0.playlist != nil }) : nil
        let currentReference = shareCurrentTrack ? track.map { CuratorSongReference(id:$0.id,title:$0.title,artist:$0.artist) } : nil
        let effectiveReference = reference ?? inherited?.songReference ?? currentReference
        let context = effectiveReference.map(AICuratorRequest.referenceContext) ?? ""
        let rules = CuratorSelectionRules.make(query:text,reference:effectiveReference,previous:reference == nil ? inherited?.selectionRules : nil)
        let originalRequest = String((((inherited?.originalRequest).map { $0 + "\nУточнение: " } ?? "") + text + context).prefix(8000))
        let yearRange = AICuratorRequest.yearRange(query:text,previousUserQueries:messages.filter { $0.role == .user }.map(\.text))
        let periodContext = AICuratorRequest.periodContext(yearRange)
        let id = UUID(), token = UUID(), account = YandexMusicService.shared.accountGeneration
        requestID = token
        var userMessage = AIMessage(role:.user,text:text + (reference == nil ? context : ""))
        userMessage.songReference = effectiveReference; userMessage.requestedYearRange = yearRange
        messages.append(userMessage)
        var answerMessage = AIMessage(id:id,role:.assistant,text:"",isStreaming:true)
        answerMessage.requestedYearRange = yearRange
        answerMessage.songReference = effectiveReference; answerMessage.selectionRules = rules
        answerMessage.originalRequest = originalRequest
        messages.append(answerMessage)
        if messages.count > AICuratorPolicy.messageLimit { messages.removeFirst(messages.count - AICuratorPolicy.messageLimit) }
        phase = web.enabled ? .searching : .thinking
        operation = Task { [weak self] in
            guard let self else { return }
            var accumulated = "", lastUpdate = Date.distantPast
            do {
                let previous = history.last(where: { $0.role == "user" }).map { String($0.content.prefix(150)) } ?? ""
                let searchQuery = AICuratorRequest.discoverySearch(query:text + (previous.isEmpty ? "" : "\nПредыдущее уточнение: " + previous),reference:effectiveReference)
                let retrieval = try await webContext(for: searchQuery, messageID: id, token: token, account: account)
                try Task.checkCancellation()
                guard requestID == token, account == YandexMusicService.shared.accountGeneration else { throw CancellationError() }
                phase = .thinking
                let result = try await ai.sendMessage(query: text + context + periodContext + rules.promptContext + retrieval + "\nГлавная музыкальная задача: " + text + rules.promptContext, history: history) { [weak self] delta in
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
                if playlistResult != nil {
                    playlistResult!.tracks = Array(playlistResult!.tracks.prefix(AICuratorPolicy.suggestionLimit)).filter { !rules.excludes($0.artist) }
                }
                let reply = AICuratorPrompt.reply(from: result.fullText)
                update(id) { $0.text = result.fullText; $0.isStreaming = false; $0.playlist = playlistResult
                    $0.requestSummary = reply?.summary; $0.clarification = reply?.intent == .clarify ? reply?.question : nil
                    if playlistResult?.tracks.isEmpty == true { $0.error = "AI предложил только исключённого исполнителя. Уточни характер песни: например, мелодичная баллада или энергичный рэп." }
                }
                if let playlist = playlistResult, !playlist.tracks.isEmpty {
                    phase = .resolving; update(id) { $0.isResolvingTracks = true }
                    let tracks = await AIPlaylistGeneratorService.shared.resolveTracks(for:playlist.tracks,yearRange:yearRange,rules:rules) { [weak self] completed,total in
                        guard let self, self.requestID == token, account == YandexMusicService.shared.accountGeneration else { return }
                        self.catalogProgress = "Проверено \(completed) из \(total) рекомендаций"
                    }
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
            phase = .idle; catalogProgress = nil; operation = nil; savePersistedState()
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
    func extend(_ messageID: UUID, count: Int = 10) {
        guard !isBusy, let message = messages.first(where: { $0.id == messageID }),
              let playlist = message.playlist, !message.resolvedTracks.isEmpty else { return }
        let token = UUID(), account = YandexMusicService.shared.accountGeneration
        let source = messages.prefix(while: { $0.id != messageID }).last(where: { $0.role == .user })
        // Older archives may not have stored an assistant-side reference/request.
        let reference = message.songReference ?? source?.songReference
        let originalRequest = message.originalRequest ?? ((source?.text ?? "") + (reference.map(AICuratorRequest.referenceContext) ?? ""))
        let rules = message.selectionRules ?? CuratorSelectionRules.make(query:source?.text ?? "",reference:reference)
        let suggestedBefore = playlist.tracks + (message.extensionSuggestions ?? [])
        let existingTracks = message.savedPlaylistID.flatMap { LibraryStore.shared.playlist(byId:$0) }.map { LibraryStore.shared.tracks(for:$0) } ?? message.resolvedTracks
        let limit = min(50,max(1,count))
        requestID = token; phase = .extending; catalogProgress = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await webContext(for: AICuratorRequest.discoverySearch(query:"Продолжение: " + String(originalRequest.prefix(500)) + ". " + String(playlist.description.prefix(150)),reference:reference),
                                                   messageID: messageID, token: token, account: account, isExtension: true)
                try Task.checkCancellation()
                guard requestID == token, account == YandexMusicService.shared.accountGeneration else { throw CancellationError() }
                let result = try await AIPlaylistGeneratorService.shared.extendPlaylistDetailed(playlistTitle:playlist.playlistTitle,
                    description:playlist.description,existingTracks:existingTracks,webContext:context,
                    yearRange:message.requestedYearRange,count:limit,originalRequest:originalRequest,rules:rules,suggestedBefore:suggestedBefore) { [weak self] completed,total in
                        guard let self, self.requestID == token, account == YandexMusicService.shared.accountGeneration else { return }
                        self.phase = .resolving; self.catalogProgress = "Проверено \(completed) из \(total) рекомендаций"
                    }
                try Task.checkCancellation()
                guard requestID == token, account == YandexMusicService.shared.accountGeneration else { return }
                let latest = message.savedPlaylistID.flatMap { LibraryStore.shared.playlist(byId:$0) }.map { LibraryStore.shared.tracks(for:$0) } ?? existingTracks
                let tracks = rules.diverse(result.tracks,existing:latest)
                update(messageID) {
                    $0.resolvedTracks = latest + tracks; $0.extendedCount = ($0.extendedCount ?? 0) + tracks.count
                    $0.extensionSuggestions = Array(((message.extensionSuggestions ?? []) + result.suggestions).suffix(200))
                    $0.extensionAttemptedCount = result.suggestions.count
                    $0.extensionMissingCount = max(0,result.suggestions.count - tracks.count)
                    $0.selectionRules = rules; $0.songReference = reference; $0.originalRequest = originalRequest
                }
                if let saved = message.savedPlaylistID, LibraryStore.shared.playlist(byId: saved) != nil {
                    LibraryStore.shared.addTracksToPlaylist(tracks: tracks, playlistId: saved)
                }
                showToast("Добавлено \(tracks.count) из \(result.suggestions.count) предложенных. Остальные не прошли точное совпадение, ограничения или проверку повторов.")
            } catch {
                guard requestID == token else { return }; showToast(error.localizedDescription)
            }
            guard requestID == token else { return }
            phase = .idle; catalogProgress = nil; operation = nil; savePersistedState()
        }
    }
    func recordLibraryExtension(playlistID: UUID, result: CuratorExtensionResult) {
        guard !isBusy, let message = messages.first(where: { $0.savedPlaylistID == playlistID }),
              let saved = LibraryStore.shared.playlist(byId:playlistID) else { return }
        update(message.id) {
            $0.resolvedTracks = LibraryStore.shared.tracks(for:saved)
            $0.extensionSuggestions = Array(((message.extensionSuggestions ?? []) + result.suggestions).suffix(200))
            $0.extendedCount = ($0.extendedCount ?? 0) + result.tracks.count
            $0.extensionAttemptedCount = result.suggestions.count
            $0.extensionMissingCount = max(0,result.suggestions.count - result.tracks.count)
        }
        savePersistedState()
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
