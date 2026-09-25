import Foundation

// MARK: - Dify API Models

public struct DifyChatRequest: Codable, Sendable {
    public let inputs: [String: String]
    public let query: String
    public let responseMode: String
    public let conversationId: String?
    public let user: String

    enum CodingKeys: String, CodingKey {
        case inputs
        case query
        case responseMode = "response_mode"
        case conversationId = "conversation_id"
        case user
    }

    public init(
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

public struct DifyChatBlockingResponse: Codable, Sendable {
    public let event: String?
    public let taskId: String?
    public let id: String?
    public let messageId: String?
    public let conversationId: String?
    public let mode: String?
    public let answer: String?
    public let createdAt: Int?

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

public struct DifyStreamChunk: Codable, Sendable {
    public let event: String?
    public let taskId: String?
    public let messageId: String?
    public let conversationId: String?
    public let answer: String?

    enum CodingKeys: String, CodingKey {
        case event
        case taskId = "task_id"
        case messageId = "message_id"
        case conversationId = "conversation_id"
        case answer
    }
}

// MARK: - AI Playlist & Music Models

public struct AIGeneratedPlaylist: Codable, Sendable, Equatable {
    public let playlistTitle: String
    public let description: String
    public let tracks: [AITrackSuggestion]

    enum CodingKeys: String, CodingKey {
        case playlistTitle = "playlist_title"
        case description
        case tracks
    }

    public init(playlistTitle: String, description: String, tracks: [AITrackSuggestion]) {
        self.playlistTitle = playlistTitle
        self.description = description
        self.tracks = tracks
    }
}

public struct AITrackSuggestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(artist)-\(title)" }
    public let artist: String
    public let title: String
    public let reason: String?

    public init(artist: String, title: String, reason: String? = nil) {
        self.artist = artist
        self.title = title
        self.reason = reason
    }
}

// MARK: - Chat UI Models

public enum AIMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct AIMessage: Identifiable, Sendable {
    public let id: UUID
    public let role: AIMessageRole
    public var text: String
    public let timestamp: Date
    public var playlist: AIGeneratedPlaylist?
    public var resolvedTracks: [Track]
    public var isStreaming: Bool
    public var isResolvingTracks: Bool
    public var error: String?

    public init(
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
