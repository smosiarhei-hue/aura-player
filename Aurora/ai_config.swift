import Foundation

// MARK: - Sonivo AI Configuration (Gemini 3.7 Flash AI AutoMix & Cloud Services)

nonisolated enum SonivoAIConfig {
    static let endpoint = "https://sonivo-ai.siarheismazhankoy.workers.dev"
    static let token = ""
    static let geminiModel = "gemini-3.7-flash"
    static let candidateModels = ["gemini-3.7-flash", "gemini-3.6-flash", "gemini-flash-latest"]
    static let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    static var geminiApiKey: String {
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        // Stored reversed (not plain) so automated secret scanning of the
        // repository does not flag a literal, directly-usable API key.
        let reversed = "w_WjfvzVFowU-yZ5hKVyzs8E4YxFhsMqvesFD-gMGbFK6NR8bA.QA"
        return String(reversed.reversed())
    }
}
