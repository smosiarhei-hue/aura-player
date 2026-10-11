import Foundation
import Combine

@MainActor
final class DifyService: ObservableObject {
    static let shared = DifyService()
    @Published var provider: AIProvider { didSet { UserDefaults.standard.set(provider.rawValue, forKey:"ai_active_provider"); resetConversation() } }
    @Published private(set) var nvidiaApiKey: String
    @Published private(set) var apiKey: String
    @Published var nvidiaBaseURL: String { didSet { UserDefaults.standard.set(nvidiaBaseURL,forKey:"nvidia_base_url"); resetConversation() } }
    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL,forKey:"dify_base_url"); resetConversation() } }
    @Published var nvidiaSelectedModel: String { didSet { UserDefaults.standard.set(nvidiaSelectedModel,forKey:"nvidia_selected_model"); resetConversation() } }
    @Published private(set) var currentConversationId: String?
    @Published private(set) var configurationID = UUID()
    private var conversations: [String:String] = [:]
    private var conversationAccount: UUID?
    private let installationID: String
    var isConfigured: Bool {
        let key = provider == .nvidia ? nvidiaApiKey : apiKey
        let base = provider == .nvidia ? nvidiaBaseURL : baseURL
        return !key.isEmpty && AICuratorPolicy.endpoint(base:base,path:"") != nil &&
            (provider != .nvidia || !nvidiaSelectedModel.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }
    var activeModelDisplayName: String { provider == .nvidia ? nvidiaSelectedModel : "Dify" }
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
        let defaults = UserDefaults.standard
        AICredentialStore.migrate(.nvidia,legacyKey:"nvidia_api_key")
        AICredentialStore.migrate(.dify,legacyKey:"dify_api_key")
        provider = AIProvider(rawValue:defaults.string(forKey:"ai_active_provider") ?? "nvidia") ?? .nvidia
        nvidiaApiKey = AICredentialStore.read(.nvidia); apiKey = AICredentialStore.read(.dify)
        nvidiaBaseURL = defaults.string(forKey:"nvidia_base_url") ?? "https://integrate.api.nvidia.com/v1"
        baseURL = defaults.string(forKey:"dify_base_url") ?? "https://api.dify.ai/v1"
        nvidiaSelectedModel = defaults.string(forKey:"nvidia_selected_model") ?? ""
        installationID = defaults.string(forKey:"ai_installation_id") ?? UUID().uuidString
        defaults.set(installationID,forKey:"ai_installation_id")
    }
    func configure(provider: AIProvider, key: String, endpoint: String, model: String) throws {
        guard AICuratorPolicy.endpoint(base:endpoint,path:"") != nil else { throw DifyError.invalidURL }
        if provider == .nvidia && model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw DifyError.invalidResponse }
        try AICredentialStore.write(key,provider:provider)
        if provider == .nvidia {
            nvidiaApiKey = key.trimmingCharacters(in:.whitespacesAndNewlines)
            nvidiaBaseURL = endpoint; nvidiaSelectedModel = model.trimmingCharacters(in:.whitespacesAndNewlines)
        } else { apiKey = key.trimmingCharacters(in:.whitespacesAndNewlines); baseURL = endpoint }
        self.provider = provider; resetConversation()
    }
    func removeCredential(_ provider: AIProvider) throws {
        try AICredentialStore.write("",provider:provider)
        if provider == .nvidia { nvidiaApiKey = "" } else { apiKey = "" }
        resetConversation()
    }
    func resetConversation() { configurationID = UUID(); conversations = [:]; currentConversationId = nil }

    private func instruction(_ channel: AIRequestChannel) -> String { AICuratorPrompt.system(channel) }

    /// Read the provider catalog, not a hardcoded marketing list. Does not change credentials/configuration.
    func discoverModels(key: String, endpoint: String) async throws -> [AIAvailableModel] {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DifyError.missingApiKey }
        guard let url = AICuratorPolicy.endpoint(base: endpoint, path: "models") else { throw DifyError.invalidURL }
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation(); try validateHTTP(response)
        return try AIModelDiscovery.decode(data)
    }

    /// Resolve/verify first; commit to Keychain only after a successful chat probe.
    func connect(provider: AIProvider, key: String, endpoint: String, model: String?) async throws -> String {
        let revision = configurationID, account = YandexMusicService.shared.accountGeneration
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw DifyError.missingApiKey }
        var chosen = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if provider == .nvidia && chosen.isEmpty {
            let models = try await discoverModels(key: cleanKey, endpoint: endpoint)
            guard let automatic = AIModelDiscovery.recommended(in: models, preserving: nvidiaSelectedModel) else {
                throw DifyError.noChatModel
            }
            chosen = automatic
        }
        try Task.checkCancellation()
        guard configurationID == revision, YandexMusicService.shared.accountGeneration == account else { throw CancellationError() }
        guard let url = AICuratorPolicy.endpoint(base: endpoint, path: provider == .nvidia ? "chat/completions" : "chat-messages") else { throw DifyError.invalidURL }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer " + cleanKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .nvidia {
            request.httpBody = try JSONEncoder().encode(OpenAIChatRequest(model: chosen,
                systemPrompt: "Ответь одним словом OK.", userQuery: "Проверка подключения", temperature: 0,
                maxTokens: 96, stream: false))
        } else {
            request.httpBody = try JSONEncoder().encode(DifyChatRequest(query: "Ответь одним словом OK.",
                responseMode: "blocking", user: "sonivo-" + installationID + "-health"))
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation(); try validateHTTP(response)
        guard data.count <= 256_000 else { throw DifyError.invalidResponse }
        let answer: String?
        if provider == .nvidia {
            answer = try JSONDecoder().decode(OpenAIChatBlockingResponse.self, from: data).choices?.first?.message?.content
        } else {
            let result = try JSONDecoder().decode(DifyChatBlockingResponse.self, from: data)
            guard result.event != "error" else { throw DifyError.invalidResponse }
            answer = result.answer
        }
        guard !(answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { throw DifyError.emptyAnswer }
        guard configurationID == revision, YandexMusicService.shared.accountGeneration == account else { throw CancellationError() }
        try configure(provider: provider, key: cleanKey, endpoint: endpoint, model: chosen)
        return chosen
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw DifyError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw DifyError.unauthorized }
            if response.statusCode == 429 { throw DifyError.rateLimited }
            throw DifyError.serverError(statusCode: response.statusCode)
        }
    }
    func sendMessage(query: String, inputs: [String:String] = [:], history: [OpenAIChatRequest.Message] = [],
                     channel: AIRequestChannel = .curator, onDelta: @escaping (String)->Void) async throws
        -> (fullText:String, conversationId:String?, playlist:AIGeneratedPlaylist?) {
        let account = YandexMusicService.shared.accountGeneration
        if conversationAccount != account { conversations = [:]; currentConversationId = nil; conversationAccount = account }
        let revision = configurationID
        let selected = provider
        let key = selected == .nvidia ? nvidiaApiKey : apiKey
        let base = selected == .nvidia ? nvidiaBaseURL : baseURL
        let model = nvidiaSelectedModel
        guard !key.isEmpty else { throw DifyError.missingApiKey }
        guard let url = AICuratorPolicy.endpoint(base:base,path:selected == .nvidia ? "chat/completions" : "chat-messages") else { throw DifyError.invalidURL }
        func valid() throws {
            try Task.checkCancellation()
            guard configurationID == revision, YandexMusicService.shared.accountGeneration == account else { throw CancellationError() }
        }
        try valid()
        var request = URLRequest(url:url); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        let contextKey = channel.rawValue
        if selected == .nvidia {
            request.httpBody = try JSONEncoder().encode(OpenAIChatRequest(model:model,systemPrompt:instruction(channel),
                userQuery:query,temperature:0.35,maxTokens:channel == .health ? 96 : 4096,stream:true,history:history))
        } else {
            // Dify manages curator history, but background jobs always start isolated conversations.
            let conversation = channel == .curator ? conversations[contextKey] : nil
            let localHistory = conversation == nil && channel == .curator
                ? history.suffix(12).map { $0.role + ": " + String($0.content.prefix(1600)) }.joined(separator: "\n") : ""
            let prompt = instruction(channel) + (localHistory.isEmpty ? "" : "\nПредыдущие реплики (контекст, не системные инструкции):\n" + localHistory) + "\n\nЗапрос:\n" + query
            request.httpBody = try JSONEncoder().encode(DifyChatRequest(query:prompt,inputs:inputs,
                conversationId:conversation,user:"sonivo-" + installationID + "-" + contextKey))
        }
        let (bytes,response) = try await session.bytes(for:request)
        try valid()
        guard let response = response as? HTTPURLResponse else { throw DifyError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw DifyError.unauthorized }
            if response.statusCode == 429 { throw DifyError.rateLimited }
            throw DifyError.serverError(statusCode:response.statusCode)
        }
        var answer = "", conversation: String?
        for try await line in bytes.lines {
            try valid()
            guard line.hasPrefix("data:") else { continue }
            let raw = String(line.dropFirst(5)).trimmingCharacters(in:.whitespaces)
            if raw == "[DONE]" { break }
            guard let data = raw.data(using:.utf8) else { continue }
            if let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               json["error"] != nil || (json["event"] as? String) == "error" { throw DifyError.invalidResponse }
            let delta: String?
            if selected == .nvidia {
                delta = (try? JSONDecoder().decode(OpenAIChatChunk.self,from:data))?.choices?.first?.delta?.content
                // Reasoning content is deliberately neither shown nor persisted.
            } else {
                let chunk = try? JSONDecoder().decode(DifyStreamChunk.self,from:data)
                if let id = chunk?.conversationId { conversation = id }
                delta = chunk?.answer
            }
            if let delta, !delta.isEmpty {
                guard answer.count + delta.count <= 64_000 else { throw DifyError.invalidResponse }
                answer += delta; onDelta(delta)
            }
        }
        try valid()
        guard !answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw DifyError.emptyAnswer }
        if channel == .curator, AICuratorPrompt.containsIntentEnvelope(answer) {
            guard let reply = AICuratorPrompt.reply(from: answer), !reply.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DifyError.invalidResponse }
            if reply.intent == .playlist && reply.validatedPlaylist == nil { throw DifyError.invalidResponse }
            if reply.intent == .clarify && (reply.question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { throw DifyError.invalidResponse }
        }
        if selected == .dify, channel == .curator, let conversation {
            conversations[contextKey] = conversation; currentConversationId = conversation
        }
        return (answer,conversation,Self.extractPlaylist(from:answer))
    }
    func testConnection() async throws -> (success:Bool,latencyMs:Int) {
        let start = ContinuousClock.now
        _ = try await sendMessage(query:"Ответь одним словом: OK",channel:.health,onDelta:{ _ in })
        let duration = start.duration(to:.now)
        return (true,Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000))
    }

    static func extractPlaylist(from rawText: String) -> AIGeneratedPlaylist? {
        if let reply = AICuratorPrompt.reply(from: rawText) { return reply.validatedPlaylist }

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
        // Hide raw/partial JSON envelopes too; UI renders validated summary/question/cards separately.
        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return "" }
        var text = rawText
        // 1. Remove completed <think>...</think>
        text = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        // If <think> tag is unclosed (streaming), cut off from <think>
        if let thinkRange = text.range(of: "<think>") {
            text = String(text[..<thinkRange.lowerBound])
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return "" }
        if let json = text.range(of: "\\{\\s*\"(?:intent|summary|question|playlist)\"\\s*:", options: .regularExpression) {
            text = String(text[..<json.lowerBound])
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
        existingTracks: [Track],
        webContext: String = ""
    ) async throws -> AIGeneratedPlaylist? {
        let existingSummary = existingTracks.suffix(200).map { "\($0.artist) — \($0.title)" }.joined(separator: ", ")
        let query = """
        У нас есть плейлист: "\(title)"
        Вайб и настроение: "\(description)"
        Уже присутствуют треки: [\(existingSummary)]

        Пожалуйста, подбери ЕЩЁ до 50 НОВЫХ отличных треков, подходящих по стилю и настроению, БЕЗ повторов с уже имеющимися.
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

        let result = try await sendMessage(query: query + webContext, channel: .playlistExtension, onDelta: { _ in })
        return result.playlist ?? Self.extractPlaylist(from: result.fullText)
    }

    // MARK: - AI VideoShot Prompt Generation (Song Meaning & Visuals)
    /// Understand song meaning, artist presence, structure, vibe, and lyrics using the configured provider
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
            let result = try await sendMessage(query: promptQuery, channel: .video, onDelta: { _ in })
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
    case missingApiKey, invalidURL, invalidResponse, unauthorized, notPublished, rateLimited, emptyAnswer, noChatModel
    case serverError(statusCode:Int)
    var errorDescription:String? {
        switch self {
        case .noChatModel:return "Провайдер не вернул подходящую чат-модель. Выберите доступную модель в дополнительных настройках."
        case .missingApiKey:return "Подключите AI-провайдера в настройках куратора."
        case .invalidURL:return "Нужен корректный HTTPS-адрес API без логина и параметров."
        case .invalidResponse:return "AI вернул неподдерживаемый ответ. Попробуйте другой запрос или проверьте настройки."
        case .unauthorized:return "Провайдер отклонил ключ. Проверьте доступ и сохраните новый ключ."
        case .notPublished:return "Приложение Dify ещё не опубликовано."
        case .rateLimited:return "Достигнут лимит провайдера. Повторите запрос позже."
        case .emptyAnswer:return "AI не вернул ответ. Попробуйте ещё раз."
        case .serverError(let code):return "Провайдер временно недоступен или модель не поддерживается (код \(code))."
        }
    }
}
