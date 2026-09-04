// Path: Aurora/VKMusic/VKModels.swift

import Foundation

nonisolated struct VKAccessToken: Codable, Sendable, Equatable {
    let value: String
    let userID: Int
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(30)
    }
}

nonisolated struct VKAPIErrorPayload: Decodable, Sendable, Equatable {
    let errorCode: Int
    let errorMessage: String

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_msg"
    }
}

nonisolated enum VKMusicError: Error, Sendable, Equatable {
    case unauthorized
    case tokenExpired
    case accessDenied
    case rateLimited
    case invalidResponse
    case unavailable
    case api(code: Int, message: String)
}

nonisolated struct VKTrackDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let ownerID: Int
    let title: String
    let artist: String
    let duration: Int
    let url: String?
    let accessKey: String?
    let album: Album?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case title
        case artist
        case duration
        case url
        case accessKey = "access_key"
        case album
    }

    nonisolated struct Album: Decodable, Sendable, Equatable {
        let id: Int?
        let ownerID: Int?
        let title: String?
        let thumb: Thumb?

        enum CodingKeys: String, CodingKey {
            case id
            case ownerID = "owner_id"
            case title
            case thumb
        }
    }

    nonisolated struct Thumb: Decodable, Sendable, Equatable {
        let photo68: String?
        let photo135: String?
        let photo270: String?
        let photo300: String?
        let photo600: String?
        let photo1200: String?

        enum CodingKeys: String, CodingKey {
            case photo68 = "photo_68"
            case photo135 = "photo_135"
            case photo270 = "photo_270"
            case photo300 = "photo_300"
            case photo600 = "photo_600"
            case photo1200 = "photo_1200"
        }

        var bestURL: String? {
            photo1200 ?? photo600 ?? photo300 ?? photo270 ?? photo135 ?? photo68
        }
    }

    var compoundID: String { "\(ownerID)_\(id)" }
    var isRestricted: Bool { url?.isEmpty != false }
}

nonisolated struct VKPlaylistDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let ownerID: Int
    let title: String
    let description: String?
    let count: Int
    let accessKey: String?
    let photo: VKTrackDTO.Thumb?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case title
        case description
        case count
        case accessKey = "access_key"
        case photo
    }
}

nonisolated struct VKListResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let count: Int
    let items: [Item]
}

nonisolated struct VKEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let response: Payload?
    let error: VKAPIErrorPayload?
}
