// Path: Packages/AutoMixV2/Sources/TrackSource/YandexDownloadModels.swift

import Foundation
import MixModels

public enum YandexAudioCodec: String, Sendable, Codable, Equatable {
    case mp3
    case aac
}

public struct YandexDownloadOption: Sendable, Equatable {
    public let url: URL
    public let codec: YandexAudioCodec
    public let bitrateKbps: Int
    public let fileExtension: String

    public init(
        url: URL,
        codec: YandexAudioCodec,
        bitrateKbps: Int,
        fileExtension: String
    ) {
        self.url = url
        self.codec = codec
        self.bitrateKbps = bitrateKbps
        self.fileExtension = fileExtension
    }
}

public protocol YandexMusicDownloadClient: Sendable {
    func metadata(for id: TrackID) async throws -> TrackMeta
    func downloadOptions(for id: TrackID, forceRefresh: Bool) async throws -> [YandexDownloadOption]
}

public struct HTTPDownloadResponse: Sendable, Equatable {
    public let temporaryFileURL: URL
    public let statusCode: Int

    public init(temporaryFileURL: URL, statusCode: Int) {
        self.temporaryFileURL = temporaryFileURL
        self.statusCode = statusCode
    }
}

public protocol HTTPDownloadClient: Sendable {
    func download(from url: URL) async throws -> HTTPDownloadResponse
}
