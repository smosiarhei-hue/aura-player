// Path: Packages/AutoMixV2/Sources/MixModels/TrackModels.swift

import Foundation

public struct TrackID: Hashable, Sendable, Codable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

public struct TrackMeta: Sendable, Codable, Equatable {
    public let id: TrackID
    public let title: String
    public let artist: String
    public let albumID: String?
    public let durationSec: Double
    public let artworkURL: URL?

    public init(
        id: TrackID,
        title: String,
        artist: String,
        albumID: String?,
        durationSec: Double,
        artworkURL: URL?
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumID = albumID
        self.durationSec = durationSec
        self.artworkURL = artworkURL
    }
}
