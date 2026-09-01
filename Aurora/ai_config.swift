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
        let b64 = "QVEuQWI4Uk42SW5CekpDTWFTZTlOMEd2dHpZd0xXN0R3alNCbWJYTjktNmk4U3pqS2FaWWc="
        if let data = Data(base64Encoded: b64), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }
}
