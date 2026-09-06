// Path: Packages/AutoMixV2/Sources/TrackSource/TrackSource.swift

import Foundation
import MixModels

public protocol TrackSource: Sendable {
    func localFileURL(for id: TrackID) async throws -> URL
    func metadata(for id: TrackID) async throws -> TrackMeta
}

public enum TrackSourceError: Error, Sendable, Equatable {
    case invalidTrackID
    case metadataUnavailable
    case noDownloadOption
    case authenticationRequired
    case trackUnavailable
    case invalidResponse
    case httpStatus(Int)
    case fileSystem(String)
}
