import Foundation
import MixModels
import TrackSource

actor AutoMixV2YandexMetadataStore {
    private var values: [TrackID: TrackMeta] = [:]
    func register(_ metadata: TrackMeta) { values[metadata.id] = metadata }
    func metadata(for id: TrackID) throws -> TrackMeta {
        guard let metadata = values[id] else { throw TrackSourceError.metadataUnavailable }; return metadata
    }
}

final class AutoMixV2YandexDownloadClient: YandexMusicDownloadClient, @unchecked Sendable {
    private let metadataStore = AutoMixV2YandexMetadataStore()
    func register(_ metadata: TrackMeta) async { await metadataStore.register(metadata) }
    func metadata(for id: TrackID) async throws -> TrackMeta { try await metadataStore.metadata(for: id) }
    func downloadOptions(for id: TrackID, forceRefresh: Bool) async throws -> [YandexDownloadOption] {
        _ = forceRefresh
        return try await Task { @MainActor in
            let info = try await YandexMusicService.shared.getStreamInfo(for: id.raw)
            let codec: YandexAudioCodec; let ext: String
            switch info.codec.lowercased() {
            case "flac": codec = .flac; ext = "flac"
            case "mp3": codec = .mp3; ext = "mp3"
            case "aac", "he-aac": codec = .aac; ext = "m4a"
            default: throw TrackSourceError.noDownloadOption
            }
            return [YandexDownloadOption(url: info.url, codec: codec,
                                         bitrateKbps: info.bitrate, fileExtension: ext)]
        }.value
    }
}
