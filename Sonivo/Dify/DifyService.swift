import Foundation
import UIKit

@MainActor
final class DifyService: ObservableObject {
    static let shared = DifyService()

    // MARK: - Storage Keys
    private let providerStorageKey = "ai_active_provider"
    private static let nvidiaApiKeyStorageKey = "nvidia_api_key"
    private let nvidiaBaseURLStorageKey = "nvidia_base_url"
    private let nvidiaModelStorageKey = "nvidia_selected_model"

    private static let difyApiKeyStorageKey = "dify_api_key"
    private let difyBaseURLStorageKey = "dify_base_url"

    // MARK: - Defaults (Сентябрь 2026)
    private let defaultNvidiaBaseURL = "https://integrate.api.nvidia.com/v1"
    private let defaultNvidiaModel = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"

    private let defaultDifyBaseURL = "https://api.dify.ai/v1"

    // MARK: - Published Properties

    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: providerStorageKey)
        }
    }

    @Published var nvidiaApiKey: String {
        didSet {
            SecureCredentialStore.write(nvidiaApiKey, account: Self.nvidiaApiKeyStorageKey)
        }
    }

    @Published var nvidiaBaseURL: String {
        didSet {
            UserDefaults.standard.set(nvidiaBaseURL, forKey: nvidiaBaseURLStorageKey)
        }
    }

    @Published var nvidiaSelectedModel: String {
        didSet {
            UserDefaults.standard.set(nvidiaSelectedModel, forKey: nvidiaModelStorageKey)
        }
    }

    @Published var apiKey: String {
        didSet {
            SecureCredentialStore.write(apiKey, account: Self.difyApiKeyStorageKey)
        }
    }

    @Published var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: difyBaseURLStorageKey)
        }
    }

    @Published var currentConversationId: String? = nil

    var isConfigured: Bool {
        switch provider {
        case .nvidia:
            return !nvidiaApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .dify:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var activeModelDisplayName: String {
        switch provider {
        case .nvidia:
            if let matched = NVIDIAAIModel.availableModels.first(where: { $0.id == nvidiaSelectedModel }) {
                return matched.displayName
            }
            return nvidiaSelectedModel
        case .dify:
            return "Dify Cloud"
        }
    }

    private init() {
        let storedProviderRaw = UserDefaults.standard.string(forKey: providerStorageKey) ?? AIProvider.nvidia.rawValue
        self.provider = AIProvider(rawValue: storedProviderRaw) ?? .nvidia

        let storedNvidiaKey = SecureCredentialStore.migrateFromUserDefaults(
            account: Self.nvidiaApiKeyStorageKey,
            legacyKey: Self.nvidiaApiKeyStorageKey
        )
        let storedNvidiaURL = UserDefaults.standard.string(forKey: nvidiaBaseURLStorageKey) ?? defaultNvidiaBaseURL
        let storedNvidiaModel = UserDefaults.standard.string(forKey: nvidiaModelStorageKey) ?? defaultNvidiaModel
        self.nvidiaApiKey = storedNvidiaKey
        self.nvidiaBaseURL = storedNvidiaURL.isEmpty ? defaultNvidiaBaseURL : storedNvidiaURL
        self.nvidiaSelectedModel = storedNvidiaModel.isEmpty ? defaultNvidiaModel : storedNvidiaModel

        let storedDifyKey = SecureCredentialStore.migrateFromUserDefaults(
            account: Self.difyApiKeyStorageKey,
            legacyKey: Self.difyApiKeyStorageKey
        )
        let storedDifyURL = UserDefaults.standard.string(forKey: difyBaseURLStorageKey) ?? defaultDifyBaseURL
        self.apiKey = storedDifyKey
        self.baseURL = storedDifyURL.isEmpty ? defaultDifyBaseURL : storedDifyURL
    }

    func resetConversation() {
        currentConversationId = nil
    }

    // MARK: - Universal Send Message Entry Point

    func sendMessage(
        query: String,
        inputs: [String: String] = [:],
        onDelta: @escaping (String) -> Void
    ) async throws -> (fullText: String, conversationId: String?, playlist: AIGeneratedPlaylist?) {
        switch provider {
        case .nvidia:
            return try await sendNVIDIAMessage(query: query, onDelta: onDelta)
        case .dify:
            return try await sendDifyMessage(query: query, inputs: inputs, onDelta: onDelta)
        }
    }

    // MARK: - NVIDIA NIM (OpenAI Chat Completions Compatible)

    private func sendNVIDIAMessage(
        query: String,
        onDelta: @escaping (String) -> Void
    ) async throws -> (fullText: String, conversationId: String?, playlist: AIGeneratedPlaylist?) {
        guard !nvidiaApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DifyError.missingApiKey
        }

        let cleanBaseURL = nvidiaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBaseURL)/chat/completions") else {
            throw DifyError.invalidURL
        }

        let systemPrompt = """
        Ты — ведущий музыкальный AI-куратор и DJ Sonivo с безупречным вкусом.
        Твой стиль общения — живой, стильный, вдохновляющий и дружелюбный, как у музыкального редактора Apple Music или радиоведущего.

        Когда пользователь просит составить плейлист, микс или подобрать музыку:
        1. Начни с 2-3 красивых, атмосферных предложений о вайбе этой подборки: опиши настроение, музыкальную текстуру и эмоции. Никогда не упоминай в тексте слова "JSON", "код", "структура", "скрипт", "формат" или технические детали.
        2. В конце своего ответа приложи данные подборки СТРОГО в блоке ```json с МИНИМУМ 50 разнообразными треками известных артистов (50-60 треков, идеально подходящих по концепции):
        ```json
        {
          "playlist_title": "Название подборки",
          "description": "Краткое описание атмосферы и настроения",
          "tracks": [
            { "artist": "Исполнитель", "title": "Название трека" }
          ]
        }
        ```
        """

        let targetModel = nvidiaSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultNvidiaModel
            : nvidiaSelectedModel

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(nvidiaApiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let bodyPayload = OpenAIChatRequest(
            model: targetModel,
            systemPrompt: systemPrompt,
            userQuery: query,
            temperature: 0.7,
            maxTokens: 4096,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(bodyPayload)

        var accumulatedAnswer = ""
        var accumulatedReasoning = ""

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DifyError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 { throw DifyError.unauthorized }
                if httpResponse.statusCode == 404 || httpResponse.statusCode >= 500 {
                    // Ошибка модели или лимит воркеров — пробуем резервную модель
                    return try await sendNVIDIAFallback(query: query, systemPrompt: systemPrompt, failedModel: targetModel, onDelta: onDelta)
                }
                throw DifyError.serverError(statusCode: httpResponse.statusCode)
            }

            for try await line in asyncBytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }

                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty else { continue }
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8) else { continue }
                if let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: data),
                   let firstChoice = chunk.choices?.first {
                    if let text = firstChoice.delta?.content, !text.isEmpty {
                        accumulatedAnswer += text
                        onDelta(text)
                    } else if let reasoning = firstChoice.delta?.reasoningContent, !reasoning.isEmpty {
                        accumulatedReasoning += reasoning
                    }
                }
            }
        } catch {
            // Если модель долго в очереди (>25s timeout) или ошибка, запускаем быстрый фолбек
            onDelta("\n\n*(Переключаюсь на скоростной отклик NVIDIA...)*\n")
            return try await sendNVIDIAFallback(query: query, systemPrompt: systemPrompt, failedModel: targetModel, onDelta: onDelta)
        }

        var playlist = Self.extractPlaylist(from: accumulatedAnswer)
        if playlist == nil && !accumulatedReasoning.isEmpty {
            playlist = Self.extractPlaylist(from: accumulatedReasoning)
        }
        let fullText = accumulatedAnswer.isEmpty ? accumulatedReasoning : accumulatedAnswer
        return (fullText, nil, playlist)
    }

    private func sendNVIDIAFallback(
        query: String,
        systemPrompt: String,
        failedModel: String,
        onDelta: @escaping (String) -> Void
    ) async throws -> (fullText: String, conversationId: String?, playlist: AIGeneratedPlaylist?) {
        let cleanBaseURL = nvidiaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBaseURL)/chat/completions") else {
            throw DifyError.invalidURL
        }

        let fallbackModel = (failedModel == "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning")
            ? "nvidia/nemotron-3-super-120b-a12b"
            : "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(nvidiaApiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25

        let bodyPayload = OpenAIChatRequest(
            model: fallbackModel,
            systemPrompt: systemPrompt,
            userQuery: query,
            temperature: 0.7,
            maxTokens: 4096,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(bodyPayload)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw DifyError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }

        var accumulated = ""
        var accumulatedReasoning = ""
        for try await line in asyncBytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: data),
                  let firstChoice = chunk.choices?.first else { continue }
            if let delta = firstChoice.delta?.content, !delta.isEmpty {
                accumulated += delta
                onDelta(delta)
            } else if let reasoning = firstChoice.delta?.reasoningContent, !reasoning.isEmpty {
                accumulatedReasoning += reasoning
            }
        }

        var playlist = Self.extractPlaylist(from: accumulated)
        if playlist == nil && !accumulatedReasoning.isEmpty {
            playlist = Self.extractPlaylist(from: accumulatedReasoning)
        }
        let finalText = accumulated.isEmpty ? accumulatedReasoning : accumulated
        return (finalText, nil, playlist)
    }

    // MARK: - Dify Cloud API

    private func sendDifyMessage(
        query: String,
        inputs: [String: String],
        onDelta: @escaping (String) -> Void
    ) async throws -> (fullText: String, conversationId: String?, playlist: AIGeneratedPlaylist?) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DifyError.missingApiKey
        }

        let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBaseURL)/chat-messages") else {
            throw DifyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let bodyPayload = DifyChatRequest(
            query: query,
            inputs: inputs,
            responseMode: "streaming",
            conversationId: currentConversationId,
            user: "sonivo-user-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "sonivo")"
        )
        request.httpBody = try JSONEncoder().encode(bodyPayload)

        var accumulatedAnswer = ""
        var activeConversationId: String? = currentConversationId

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DifyError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 { throw DifyError.unauthorized }
            throw DifyError.serverError(statusCode: httpResponse.statusCode)
        }

        for try await line in asyncBytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }

            let jsonPayload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !jsonPayload.isEmpty, jsonPayload != "[DONE]" else { continue }

            guard let data = jsonPayload.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(DifyStreamChunk.self, from: data) {
                if let convId = chunk.conversationId, !convId.isEmpty {
                    activeConversationId = convId
                }
                if let textDelta = chunk.answer, !textDelta.isEmpty {
                    accumulatedAnswer += textDelta
                    onDelta(textDelta)
                }
            }
        }

        self.currentConversationId = activeConversationId
        let playlist = Self.extractPlaylist(from: accumulatedAnswer)
        return (accumulatedAnswer, activeConversationId, playlist)
    }

    // MARK: - Health / Connection Test

    func testConnection() async throws -> (success: Bool, latencyMs: Int) {
        let startTime = CFAbsoluteTimeGetCurrent()

        switch provider {
        case .nvidia:
            guard !nvidiaApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DifyError.missingApiKey
            }
            let cleanBaseURL = nvidiaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(cleanBaseURL)/models") else {
                throw DifyError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(nvidiaApiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw DifyError.invalidResponse }
            if httpResponse.statusCode == 401 { throw DifyError.unauthorized }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw DifyError.serverError(statusCode: httpResponse.statusCode)
            }
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            return (true, elapsed)

        case .dify:
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DifyError.missingApiKey
            }
            let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(cleanBaseURL)/chat-messages") else {
                throw DifyError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10

            let bodyPayload = DifyChatRequest(query: "ping", inputs: [:], responseMode: "blocking", conversationId: nil, user: "ping-test")
            request.httpBody = try? JSONEncoder().encode(bodyPayload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw DifyError.invalidResponse }
            if httpResponse.statusCode == 401 { throw DifyError.unauthorized }
            if (200...299).contains(httpResponse.statusCode) {
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                return (true, elapsed)
            }
            if let errStr = String(data: data, encoding: .utf8), (errStr.contains("Workflow not published") || errStr.contains("app_unavailable")) {
                throw DifyError.notPublished
            }
            throw DifyError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Robust JSON Playlist Extraction

    static func extractPlaylist(from rawText: String) -> AIGeneratedPlaylist? {
        // 1. Поиск блока ```json ... ```
        if let codeBlockRange = rawText.range(of: "```json([\\s\\S]*?)```", options: .regularExpression) {
            let match = String(rawText[codeBlockRange])
            let cleaned = match
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let playlist = decodePlaylistJSON(from: cleaned) {
                return playlist
            }
        }

        // 2. Поиск блока ``` ... ```
        if let genericBlockRange = rawText.range(of: "```([\\s\\S]*?)```", options: .regularExpression) {
            let match = String(rawText[genericBlockRange])
            let cleaned = match
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let playlist = decodePlaylistJSON(from: cleaned) {
                return playlist
            }
        }

        // 3. Поиск JSON объекта { ... "tracks" ... }
        if let openBrace = rawText.range(of: "{\"playlist_title\"", options: .caseInsensitive)?.lowerBound ??
            rawText.range(of: "{\"tracks\"", options: .caseInsensitive)?.lowerBound ??
            rawText.range(of: "{")?.lowerBound,
           let closeBrace = rawText.range(of: "}", options: .backwards)?.upperBound,
           openBrace < closeBrace {
            let candidate = String(rawText[openBrace..<closeBrace])
            if let playlist = decodePlaylistJSON(from: candidate) {
                return playlist
            }
        }

        return nil
    }

    static func cleanDisplayText(from rawText: String) -> String {
        var text = rawText
        // 1. Remove completed <think>...</think>
        text = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        // If <think> tag is unclosed (streaming), cut off from <think>
        if let thinkRange = text.range(of: "<think>") {
            text = String(text[..<thinkRange.lowerBound])
        }

        // 2. Strip completed markdown blocks
        text = text.replacingOccurrences(of: "```json([\\s\\S]*?)```", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "```([\\s\\S]*?)```", with: "", options: .regularExpression)

        // 3. Cut off at opening code block fence (streaming JSON block)
        if let fenceRange = text.range(of: "```") {
            text = String(text[..<fenceRange.lowerBound])
        }

        // 4. Cut off if raw JSON starts without backticks
        if let jsonStart = text.range(of: "{\"playlist_title\"", options: .caseInsensitive)?.lowerBound ??
           text.range(of: "{\n  \"playlist_title\"", options: .caseInsensitive)?.lowerBound ??
           text.range(of: "{\"tracks\"", options: .caseInsensitive)?.lowerBound ??
           text.range(of: "{\n  \"tracks\"", options: .caseInsensitive)?.lowerBound {
            text = String(text[..<jsonStart])
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    /// Запрос к ИИ на интеллектуальное дополнение плейлиста ещё 50 новыми треками того же вайба
    func extendPlaylist(
        title: String,
        description: String,
        existingTracks: [Track]
    ) async throws -> AIGeneratedPlaylist? {
        let existingSummary = existingTracks.prefix(25).map { "\($0.artist) — \($0.title)" }.joined(separator: ", ")
        let query = """
        У нас есть плейлист: "\(title)"
        Вайб и настроение: "\(description)"
        Уже присутствуют треки: [\(existingSummary)]

        Пожалуйста, подбери ЕЩЁ ровно 50 НОВЫХ отличных треков, подходящих по стилю и настроению, БЕЗ повторов с уже имеющимися.
        Выведи результат СТРОГО в блоке ```json:
        ```json
        {
          "playlist_title": "\(title)",
          "description": "\(description)",
          "tracks": [
            { "artist": "Исполнитель", "title": "Название трека" }
          ]
        }
        ```
        """

        let result = try await sendMessage(query: query, onDelta: { _ in })
        return result.playlist ?? Self.extractPlaylist(from: result.fullText)
    }

    // MARK: - AI VideoShot Prompt Generation (Song Meaning & Visuals)
    /// Understand song meaning, artist presence, structure, vibe, and lyrics using NVIDIA DeepSeek V4.1 Flash / Dify
    /// to generate a cinematic, diverse, artist-focused MiniMax video prompt with strict anti-cliché & anti-kissing rules.
    func generateVideoShotPrompt(
        title: String,
        artist: String,
        lyricsSnippet: String?,
        genre: String? = nil,
        bpm: Double? = nil,
        energy: Double? = nil,
        valence: Double? = nil,
        vibeStyle: String? = nil
    ) async -> String {
        let snippet = lyricsSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tempoBPM = Int(bpm ?? 120)
        let resolvedGenre = (genre?.isEmpty == false) ? genre! : "Modern"
        let resolvedVibe = vibeStyle ?? "Dynamic Rhythmic"

        let promptQuery = """
        You are a visionary music video director creating a 9:16 vertical looping music video for the song "\(title)" by the musical artist "\(artist)".
        Musical Context:
        - Genre: \(resolvedGenre)
        - Tempo / Rhythm: \(tempoBPM) BPM
        - Vibe & Energy: \(resolvedVibe) (Energy: \(Int((energy ?? 0.6) * 100))%, Mood valence: \(Int((valence ?? 0.5) * 100))%)
        \(snippet.isEmpty ? "" : "- Lyrics / Story: \"\(snippet.prefix(400))\"")

        DIRECTOR INSTRUCTIONS:
        1. ARTIST PERFORMANCE: The visual MUST feature the musical artist "\(artist)" in a charismatic solo music video performance (e.g. singing into a microphone on stage, rhythmic movement in a high-tech or moody studio, performing amidst cinematic atmospheric elements matching the track's theme).
        2. DIVERSITY & SONG STRUCTURE: Tailor the setting specifically to the song's genre and lyrics story. Do not make it generic. Reflect the \(tempoBPM) BPM pulse and vibe in the lighting and movement.
        3. STRICT NEGATIVE CONSTRAINTS (CRITICAL):
           - ABSOLUTELY NO KISSING.
           - ABSOLUTELY NO ROMANTIC COUPLE EMBRACES OR INTIMACY.
           - NO CHEESY ROMANTIC TROPE.
           - The video is a SOLO music performance of the artist "\(artist)".
        4. Output format: Write exactly 2 vivid sentences in English describing:
           (1) The musical artist "\(artist)" performing passionately to the rhythm in a unique cinematic setting.
           (2) Dynamic cinematic lighting, camera movement (tracking, subtle pan or orbit), and atmospheric particle/lens flare effects.
        5. Output ONLY the 2 English sentences without quotes, numbering, or preamble.
        """

        do {
            let result = try await sendMessage(query: promptQuery, onDelta: { _ in })
            var cleaned = Self.cleanDisplayText(from: result.fullText)
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            cleaned = cleaned.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")

            if !cleaned.lowercased().contains("no kissing") {
                cleaned += " Solo musical performance, absolutely no kissing."
            }

            if cleaned.count > 25 {
                return cleaned
            }
        } catch {
            SonivoDiagnostics.log("[VideoShot] NVIDIA AI prompt fallback: \(error.localizedDescription)", tag: "VIDEOSHOT")
        }

        return proceduralArtistPrompt(
            title: title,
            artist: artist,
            bpm: tempoBPM,
            vibeStyle: resolvedVibe,
            energy: energy ?? 0.6
        )
    }

    /// Процедурная генерация богатых вариативных промптов с участием артиста и защитой от клише поцелуев
    private func proceduralArtistPrompt(
        title: String,
        artist: String,
        bpm: Int,
        vibeStyle: String,
        energy: Double
    ) -> String {
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistName = cleanArtist.isEmpty ? "The lead artist" : cleanArtist

        if vibeStyle.contains("Neon") || energy > 0.75 {
            return "The musical artist \(artistName) delivering an energetic solo performance with a microphone on a concert stage illuminated by pulsing neon lasers and volumetric smoke, synchronized to the driving \(bpm) BPM rhythm. Dynamic orbiting camera with anamorphic lens flare and crisp cinematic contrast. Solo performance, absolutely no kissing."
        } else if vibeStyle.contains("Twilight") || vibeStyle.contains("Rain") || energy < 0.4 {
            return "The musical artist \(artistName) in an emotional solo performance amidst a rain-slicked nocturnal city bathed in deep sapphire streetlights and glowing bokeh, immersed in the bittersweet atmosphere of \(title). Smooth slow tracking camera with moody atmospheric fog and cinematic depth of field. Solitary solo performance, no romance, no kissing."
        } else if vibeStyle.contains("Sunset") || vibeStyle.contains("Groove") {
            return "The musical artist \(artistName) performing with effortless rhythmic groove in a warm sun-drenched studio surrounded by vintage audio gear and golden hour light rays, feeling the upbeat tempo of \(title). Fluid gliding camera movement with floating dust motes and vibrant cinematic color grade. Solo artist performance, no kissing."
        } else if vibeStyle.contains("Acoustic") {
            return "The musical artist \(artistName) performing an intimate acoustic session under warm amber spotlighting with a vintage condenser microphone, deeply connected to the soul of \(title). Gentle cinematic panning camera with soft bokeh and organic film grain. Solo music performance, no kissing."
        } else {
            return "The musical artist \(artistName) performing as a solitary figure surrounded by surreal floating stardust and ethereal light waves, their expressive motion resonating with the cosmic rhythm of \(title). Hypnotic drift camera with iridescent prism light refractions and deep atmospheric glow. Solo performance, absolutely no kissing."
        }
    }

    private static func decodePlaylistJSON(from string: String) -> AIGeneratedPlaylist? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIGeneratedPlaylist.self, from: data)
    }
}

enum DifyError: LocalizedError {
    case missingApiKey
    case invalidURL
    case invalidResponse
    case unauthorized
    case notPublished
    case serverError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "Не настроен API-ключ. Проверьте настройки провайдера AI."
        case .invalidURL:
            return "Некорректный адрес сервера API."
        case .invalidResponse:
            return "Некорректный ответ от облачного сервера."
        case .unauthorized:
            return "Ошибка авторизации: неверный API-ключ (Bearer token)."
        case .notPublished:
            return "Бот создан в Dify, но не опубликован! Нажмите кнопку «Publish» в Dify."
        case .serverError(let code):
            return "Ошибка сервера (код \(code))."
        }
    }
}
