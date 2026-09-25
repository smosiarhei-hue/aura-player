import Foundation

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
