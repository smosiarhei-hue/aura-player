import Foundation

@MainActor
final class AIDJService: ObservableObject {
    static let shared = AIDJService()

    @Published var currentDJCommentary: String?
    @Published var isGeneratingCommentary = false
    @Published var isVibeWaveGenerating = false

    private var commentaryCache: [String: String] = [:]
    private var prefetchTask: Task<Void, Never>?

    private init() {}

    // MARK: - 1. AI Vibe Wave Generation (AI Вайб-волна)

    func generateVibeWave(for seedTrack: Track) async throws -> (tracks: [Track], title: String, description: String) {
        isVibeWaveGenerating = true
        defer { isVibeWaveGenerating = false }

        let prompt = """
        Подбери 8-10 треков с точно таким же вайбом, настроением, темпом и атмосферой, как трек "\(seedTrack.artist) - \(seedTrack.title)".
        Опиши вайб в 1-2 коротких предложениях и верни JSON со списком треков строго по шаблону.
        """

        let (fullAnswer, _, playlist) = try await DifyService.shared.sendMessage(query: prompt) { _ in }

        guard let playlist = playlist, !playlist.tracks.isEmpty else {
            // Фолбек: если JSON не вернулся
            let cleanDesc = DifyService.cleanDisplayText(from: fullAnswer)
            return ([], "Вайб-волна: \(seedTrack.title)", cleanDesc)
        }

        let resolvedTracks = await AIPlaylistGeneratorService.shared.resolveTracks(for: playlist.tracks)
        return (resolvedTracks, playlist.playlistTitle, playlist.description)
    }

    // MARK: - 2. AI DJ Transition Commentary (AI DJ в переходах)

    func commentary(outgoing: Track, incoming: Track, transitionType: String = "AutoMix") async -> String {
        let key = "\(outgoing.id.uuidString)-\(incoming.id.uuidString)"
        if let cached = commentaryCache[key], !cached.isEmpty {
            currentDJCommentary = cached
            return cached
        }

        // Мгновенный умный музыкальный фолбек (чтобы слушатель не ждал секунды тишины)
        let fastFallback = generateFastFallback(outgoing: outgoing, incoming: incoming)
        currentDJCommentary = fastFallback

        // Фоновый запрос к Dify Cloud для получения живого авторского комментария
        isGeneratingCommentary = true
        defer { isGeneratingCommentary = false }

        let prompt = """
        Ты — харизматичный AI DJ на радио Sonivo.
        Мы бесшовно сводим трек "\(outgoing.artist) — \(outgoing.title)" с треком "\(incoming.artist) — \(incoming.title)" (сведение: \(transitionType)).
        Дай одну короткую, сочную фразу-подводку (строго до 10-12 слов) для слушателя об этом переходе и смене настроения. Без кавычек, без смайлов в начале и строго без JSON.
        """

        do {
            let (answer, _, _) = try await DifyService.shared.sendMessage(query: prompt) { _ in }
            let cleaned = cleanDJAnswer(answer)
            if !cleaned.isEmpty {
                commentaryCache[key] = cleaned
                currentDJCommentary = cleaned
                return cleaned
            }
        } catch {
            // Используем быстрый музыкальный фолбек при сетевых задержках
        }

        commentaryCache[key] = fastFallback
        return fastFallback
    }

    func prefetchCommentaryIfNeeded(outgoing: Track?, incoming: Track?) {
        guard let outgoing, let incoming, outgoing.id != incoming.id else { return }
        let key = "\(outgoing.id.uuidString)-\(incoming.id.uuidString)"
        guard commentaryCache[key] == nil else { return }

        prefetchTask?.cancel()
        prefetchTask = Task {
            _ = await commentary(outgoing: outgoing, incoming: incoming)
        }
    }

    func clearActiveCommentary() {
        currentDJCommentary = nil
        isGeneratingCommentary = false
    }

    // MARK: - Helpers

    private func cleanDJAnswer(_ text: String) -> String {
        var res = text
            .replacingOccurrences(of: "```json([\\s\\S]*?)```", with: "", options: .regularExpression)
            .replacingOccurrences(of: "```([\\s\\S]*?)```", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let firstLine = res.split(separator: "\n").first {
            res = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return res
    }

    private func generateFastFallback(outgoing: Track, incoming: Track) -> String {
        let options = [
            "Плавный переход: от \(outgoing.artist) прямо к саунду \(incoming.artist)!",
            "Удерживаем плотный грув: на деке \(incoming.artist) — \(incoming.title)!",
            "Переключаем вайб: встречаем \(incoming.artist)!",
            "Идеальная связка настроения от \(outgoing.artist) к \(incoming.artist)!"
        ]
        return options.randomElement() ?? "Бесшовный переход к \(incoming.artist)!"
    }
}
