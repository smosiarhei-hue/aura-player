import Foundation
import UIKit

@MainActor
final class DifyService: ObservableObject {
    static let shared = DifyService()

    // MARK: - Storage Keys
    private let providerStorageKey = "ai_active_provider"
    private let nvidiaApiKeyStorageKey = "nvidia_api_key"
    private let nvidiaBaseURLStorageKey = "nvidia_base_url"
    private let nvidiaModelStorageKey = "nvidia_selected_model"

    private let difyApiKeyStorageKey = "dify_api_key"
    private let difyBaseURLStorageKey = "dify_base_url"

    // MARK: - Defaults (Сентябрь 2026)
    private let defaultNvidiaApiKey = "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"
    private let defaultNvidiaBaseURL = "https://integrate.api.nvidia.com/v1"
    private let defaultNvidiaModel = "deepseek-ai/deepseek-v4.1-flash"

    private let defaultDifyApiKey = "app-58WNo9d5oTTMdQgDTeohiwu9"
    private let defaultDifyBaseURL = "https://api.dify.ai/v1"

    // MARK: - Published Properties

    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: providerStorageKey)
        }
    }

    @Published var nvidiaApiKey: String {
        didSet {
            UserDefaults.standard.set(nvidiaApiKey, forKey: nvidiaApiKeyStorageKey)
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
            UserDefaults.standard.set(apiKey, forKey: difyApiKeyStorageKey)
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

        let storedNvidiaKey = UserDefaults.standard.string(forKey: nvidiaApiKeyStorageKey) ?? ""
        let storedNvidiaURL = UserDefaults.standard.string(forKey: nvidiaBaseURLStorageKey) ?? defaultNvidiaBaseURL
        let storedNvidiaModel = UserDefaults.standard.string(forKey: nvidiaModelStorageKey) ?? defaultNvidiaModel
        self.nvidiaApiKey = storedNvidiaKey.isEmpty ? defaultNvidiaApiKey : storedNvidiaKey
        self.nvidiaBaseURL = storedNvidiaURL.isEmpty ? defaultNvidiaBaseURL : storedNvidiaURL
        self.nvidiaSelectedModel = storedNvidiaModel.isEmpty ? defaultNvidiaModel : storedNvidiaModel

        let storedDifyKey = UserDefaults.standard.string(forKey: difyApiKeyStorageKey) ?? ""
        let storedDifyURL = UserDefaults.standard.string(forKey: difyBaseURLStorageKey) ?? defaultDifyBaseURL
        self.apiKey = storedDifyKey.isEmpty ? defaultDifyApiKey : storedDifyKey
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
        Ты — профессиональный музыкальный AI-куратор и DJ в приложении Sonivo.
        Твоя задача — точно понимать настроение, вайб, ритм и музыкальные предпочтения пользователя.
        Всегда подбирай реальные, существующие треки известных артистов.

        Когда просят составить плейлист или подборку:
        1. Сделай краткое красивое описание атмосферы и вайба (1-2 предложения).
        2. В конце ответа ОБЯЗАТЕЛЬНО приложи JSON строго в таком формате:
        ```json
        {
          "playlist_title": "Название подборки",
          "description": "Краткое описание атмосферы",
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
        request.timeoutInterval = 45

        let bodyPayload = OpenAIChatRequest(
            model: targetModel,
            systemPrompt: systemPrompt,
            userQuery: query,
            temperature: 0.7,
            maxTokens: 1200,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(bodyPayload)

        var accumulatedAnswer = ""

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DifyError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 { throw DifyError.unauthorized }
                if httpResponse.statusCode == 404 {
                    // Модель не найдена в каталоге, пробуем быстрый фолбек
                    return try await sendNVIDIAFallback(query: query, systemPrompt: systemPrompt, onDelta: onDelta)
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
                   let firstChoice = chunk.choices?.first,
                   let text = firstChoice.delta?.content,
                   !text.isEmpty {
                    accumulatedAnswer += text
                    onDelta(text)
                }
            }
        } catch {
            // Если модель долго в очереди (>15-20s timeout), запускаем быстрый фолбек на ultra-fast Nemotron
            if targetModel != "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning" {
                onDelta("\n\n*(Переключаюсь на скоростной отклик NVIDIA...)*\n")
                return try await sendNVIDIAFallback(query: query, systemPrompt: systemPrompt, onDelta: onDelta)
            }
            throw error
        }

        let playlist = Self.extractPlaylist(from: accumulatedAnswer)
        return (accumulatedAnswer, nil, playlist)
    }

    private func sendNVIDIAFallback(
        query: String,
        systemPrompt: String,
        onDelta: @escaping (String) -> Void
    ) async throws -> (fullText: String, conversationId: String?, playlist: AIGeneratedPlaylist?) {
        let cleanBaseURL = nvidiaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBaseURL)/chat/completions") else {
            throw DifyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(nvidiaApiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let bodyPayload = OpenAIChatRequest(
            model: "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
            systemPrompt: systemPrompt,
            userQuery: query,
            temperature: 0.7,
            maxTokens: 1024,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(bodyPayload)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw DifyError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }

        var accumulated = ""
        for try await line in asyncBytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: data),
                  let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty else { continue }
            accumulated += delta
            onDelta(delta)
        }

        let playlist = Self.extractPlaylist(from: accumulated)
        return (accumulated, nil, playlist)
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
            user: "sonivo-user-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "aura")"
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
        var cleaned = rawText.replacingOccurrences(of: "```json([\\s\\S]*?)```", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "```([\\s\\S]*?)```", with: "", options: .regularExpression)
        // Убираем теги <think>...</think> если модель рассуждала
        cleaned = cleaned.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Вот подборка треков по твоему запросу:" : cleaned
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
