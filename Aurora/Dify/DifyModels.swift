import Foundation

// MARK: - AI Provider

enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case nvidia = "nvidia"
    case dify = "dify"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nvidia: return "NVIDIA NIM"
        case .dify: return "Dify Cloud"
        }
    }

    var subtitle: String {
        switch self {
        case .nvidia: return "DeepSeek V4.1 Flash, Nemotron 3 и актуальные модели сентября 2026"
        case .dify: return "Собственные агенты и пайплайны Dify Workflow"
        }
    }
}

// MARK: - NVIDIA NIM Models (Актуальные на сентябрь 2026)

struct NVIDIAAIModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let summary: String
    let badge: String
    let isRecommended: Bool

    static let availableModels: [NVIDIAAIModel] = [
        NVIDIAAIModel(
            id: "deepseek-ai/deepseek-v4.1-flash",
            displayName: "DeepSeek V4.1 Flash",
            summary: "Флагманский MoE Flash 2026 года для музыкального анализа и глубокого подбора треков.",
            badge: "Выбор пользователя",
            isRecommended: true
        ),
        NVIDIAAIModel(
            id: "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
            displayName: "Nemotron 3 Nano Omni (30B)",
            summary: "Сверхскоростной отклик (~1.8 сек), точное понимание настроений и живые рекомендации.",
            badge: "⚡ 1.8s Ultra-Fast",
            isRecommended: true
        ),
        NVIDIAAIModel(
            id: "nvidia/nemotron-3-super-120b-a12b",
            displayName: "Nemotron 3 Super (120B)",
            summary: "Мощная 120-миллиардная модель с энциклопедическим кругозором в музыке и редких жанрах.",
            badge: "120B MoE",
            isRecommended: false
        ),
        NVIDIAAIModel(
            id: "nvidia/nemotron-3-ultra-550b-a55b",
            displayName: "Nemotron 3 Ultra (550B)",
            summary: "Максимальная интеллектуальная глубина для сложных концептуальных плейлистов.",
            badge: "550B Ultra",
            isRecommended: false
        ),
        NVIDIAAIModel(
            id: "nvidia/nemotron-3.5-lightning-30b-a3b",
            displayName: "Nemotron 3.5 Lightning (30B)",
            summary: "Специализированная скоростная модель для мгновенных DJ-подводок и диалогов.",
            badge: "Lightning",
            isRecommended: false
        ),
        NVIDIAAIModel(
            id: "z-ai/glm-5.3-flash",
            displayName: "GLM 5.3 Flash",
            summary: "Быстрая компактная модель для генерации лаконичных списков треков.",
            badge: "Flash",
            isRecommended: false
        ),
        NVIDIAAIModel(
            id: "moonshotai/kimi-k3",
            displayName: "Kimi K3",
            summary: "Глубокое понимание длинных запросов, контекста и сложных переходов.",
            badge: "Reasoning",
            isRecommended: false
        )
    ]
}

// MARK: - OpenAI / NVIDIA NIM Chat Completions Models

struct OpenAIChatRequest: Codable, Sendable {
    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }

    init(
        model: String,
        systemPrompt: String,
        userQuery: String,
        temperature: Double = 0.7,
        maxTokens: Int = 1024,
        stream: Bool = true
    ) {
        self.model = model
        self.messages = [
            Message(role: "system", content: systemPrompt),
            Message(role: "user", content: userQuery)
        ]
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
    }
}

struct OpenAIChatChunk: Codable, Sendable {
    struct Choice: Codable, Sendable {
        struct Delta: Codable, Sendable {
            let content: String?
            let role: String?
        }
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]?
}

struct OpenAIChatBlockingResponse: Codable, Sendable {
    struct Choice: Codable, Sendable {
        struct Message: Codable, Sendable {
            let role: String?
            let content: String?
        }
        let message: Message?
    }
    let choices: [Choice]?
}

// MARK: - Dify API Models

struct DifyChatRequest: Codable, Sendable {
    let inputs: [String: String]
    let query: String
    let responseMode: String
    let conversationId: String?
    let user: String

    enum CodingKeys: String, CodingKey {
        case inputs
        case query
        case responseMode = "response_mode"
        case conversationId = "conversation_id"
        case user
    }

    init(
        query: String,
        inputs: [String: String] = [:],
        responseMode: String = "streaming",
        conversationId: String? = nil,
        user: String = "sonivo-user"
    ) {
        self.query = query
        self.inputs = inputs
        self.responseMode = responseMode
        self.conversationId = conversationId
        self.user = user
    }
}

struct DifyChatBlockingResponse: Codable, Sendable {
    let event: String?
    let taskId: String?
    let id: String?
    let messageId: String?
    let conversationId: String?
    let mode: String?
    let answer: String?
    let createdAt: Int?

    enum CodingKeys: String, CodingKey {
        case event
        case taskId = "task_id"
        case id
        case messageId = "message_id"
        case conversationId = "conversation_id"
        case mode
        case answer
        case createdAt = "created_at"
    }
}

struct DifyStreamChunk: Codable, Sendable {
    let event: String?
    let taskId: String?
    let messageId: String?
    let conversationId: String?
    let answer: String?

    enum CodingKeys: String, CodingKey {
        case event
        case taskId = "task_id"
        case messageId = "message_id"
        case conversationId = "conversation_id"
        case answer
    }
}

// MARK: - AI Playlist & Music Models

struct AIGeneratedPlaylist: Codable, Sendable, Equatable {
    let playlistTitle: String
    let description: String
    let tracks: [AITrackSuggestion]

    enum CodingKeys: String, CodingKey {
        case playlistTitle = "playlist_title"
        case description
        case tracks
    }

    init(playlistTitle: String, description: String, tracks: [AITrackSuggestion]) {
        self.playlistTitle = playlistTitle
        self.description = description
        self.tracks = tracks
    }
}

struct AITrackSuggestion: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(artist)-\(title)" }
    let artist: String
    let title: String
    let reason: String?

    init(artist: String, title: String, reason: String? = nil) {
        self.artist = artist
        self.title = title
        self.reason = reason
    }
}

// MARK: - Chat UI Models

enum AIMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct AIMessage: Identifiable, Sendable {
    let id: UUID
    let role: AIMessageRole
    var text: String
    let timestamp: Date
    var playlist: AIGeneratedPlaylist?
    var resolvedTracks: [Track]
    var isStreaming: Bool
    var isResolvingTracks: Bool
    var error: String?

    init(
        id: UUID = UUID(),
        role: AIMessageRole,
        text: String,
        timestamp: Date = Date(),
        playlist: AIGeneratedPlaylist? = nil,
        resolvedTracks: [Track] = [],
        isStreaming: Bool = false,
        isResolvingTracks: Bool = false,
        error: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.playlist = playlist
        self.resolvedTracks = resolvedTracks
        self.isStreaming = isStreaming
        self.isResolvingTracks = isResolvingTracks
        self.error = error
    }
}
