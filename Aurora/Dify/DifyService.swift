import Foundation
import UIKit

@MainActor
final class DifyService: ObservableObject {
    static let shared = DifyService()

    private let apiKeyStorageKey = "dify_api_key"
    private let baseURLStorageKey = "dify_base_url"
    private let defaultBaseURL = "https://api.dify.ai/v1"
    private let defaultApiKey = "app-58WNo9d5oTTMdQgDTeohiwu9"

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: apiKeyStorageKey)
        }
    }

    @Published var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: baseURLStorageKey)
        }
    }

    @Published var currentConversationId: String? = nil

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private init() {
        let storedKey = UserDefaults.standard.string(forKey: apiKeyStorageKey) ?? ""
        let storedBaseURL = UserDefaults.standard.string(forKey: baseURLStorageKey) ?? defaultBaseURL
        self.apiKey = storedKey.isEmpty ? defaultApiKey : storedKey
        self.baseURL = storedBaseURL.isEmpty ? defaultBaseURL : storedBaseURL
    }

    func resetConversation() {
        currentConversationId = nil
    }

    // MARK: - Send Message (SSE Streaming)

    func sendMessage(
        query: String,
        inputs: [String: String] = [:],
        onDelta: @escaping (String) -> Void
    ) async throws -> (fullText: String, conversationId: String?, playlist: AIGeneratedPlaylist?) {
        guard isConfigured else {
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

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DifyError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 {
                    throw DifyError.unauthorized
                }
                // Try blocking fallback to inspect body for specific Dify error
                return try await sendBlockingFallback(query: query, inputs: inputs, onDelta: onDelta)
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
        } catch let error as DifyError {
            throw error
        } catch {
            // Fallback: try blocking mode if streaming fails on network/proxy
            return try await sendBlockingFallback(query: query, inputs: inputs, onDelta: onDelta)
        }

        self.currentConversationId = activeConversationId
        let playlist = Self.extractPlaylist(from: accumulatedAnswer)
        return (accumulatedAnswer, activeConversationId, playlist)
    }

    // MARK: - Blocking Fallback

    private func sendBlockingFallback(
        query: String,
        inputs: [String: String],
        onDelta: @escaping (String) -> Void
    ) async throws -> (fullText: String, conversationId: String?, playlist: AIGeneratedPlaylist?) {
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
            responseMode: "blocking",
            conversationId: currentConversationId,
            user: "sonivo-user-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "aura")"
        )
        request.httpBody = try JSONEncoder().encode(bodyPayload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DifyError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 { throw DifyError.unauthorized }
            if let errStr = String(data: data, encoding: .utf8) {
                if errStr.contains("Workflow not published") || errStr.contains("app_unavailable") {
                    throw DifyError.notPublished
                }
            }
            throw DifyError.serverError(statusCode: httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(DifyChatBlockingResponse.self, from: data)
        let answer = decoded.answer ?? ""
        onDelta(answer)
        if let convId = decoded.conversationId {
            self.currentConversationId = convId
        }
        let playlist = Self.extractPlaylist(from: answer)
        return (answer, decoded.conversationId, playlist)
    }

    // MARK: - Health / Connection Test

    func testConnection() async throws -> Bool {
        guard isConfigured else { throw DifyError.missingApiKey }

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

        let bodyPayload = DifyChatRequest(
            query: "ping",
            inputs: [:],
            responseMode: "blocking",
            conversationId: nil,
            user: "ping-test"
        )
        request.httpBody = try? JSONEncoder().encode(bodyPayload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 { throw DifyError.unauthorized }
            if (200...299).contains(httpResponse.statusCode) { return true }
            if let errStr = String(data: data, encoding: .utf8) {
                if errStr.contains("Workflow not published") || errStr.contains("app_unavailable") {
                    throw DifyError.notPublished
                }
            }
            throw DifyError.serverError(statusCode: httpResponse.statusCode)
        }
        return false
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
        // Убираем JSON-блок ```json ... ``` из отображаемого сообщения, так как он красиво показывается карточкой
        var cleaned = rawText.replacingOccurrences(of: "```json([\\s\\S]*?)```", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "```([\\s\\S]*?)```", with: "", options: .regularExpression)
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
            return "Не настроен API-ключ Dify. Перейдите в настройки ассистента."
        case .invalidURL:
            return "Некорректный адрес сервера Dify."
        case .invalidResponse:
            return "Некорректный ответ от Dify Cloud."
        case .unauthorized:
            return "Ошибка авторизации: неверный API-ключ Dify (Bearer token)."
        case .notPublished:
            return "Бот создан в Dify, но не опубликован! Откройте cloud.dify.ai и нажмите синюю кнопку «Publish» (Опубликовать) в правом верхнем углу бота."
        case .serverError(let code):
            return "Ошибка сервера Dify (код \(code))."
        }
    }
}
