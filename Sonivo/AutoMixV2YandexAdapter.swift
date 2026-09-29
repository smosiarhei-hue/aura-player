import Foundation
import MixModels
import TrackSource

actor AutoMixV2YandexMetadataStore {
    private var values: [TrackID: TrackMeta] = [:]
    private var streamInfos: [TrackID: (codec: String, bitrate: Int)] = [:]
    func register(_ metadata: TrackMeta) { values[metadata.id] = metadata }
    func metadata(for id: TrackID) throws -> TrackMeta {
        guard let metadata = values[id] else { throw TrackSourceError.metadataUnavailable }; return metadata
    }
    func registerStreamInfo(codec: String, bitrate: Int, for id: TrackID) {
        streamInfos[id] = (codec, bitrate)
    }
    func streamInfo(for id: TrackID) -> (codec: String, bitrate: Int)? {
        streamInfos[id]
    }
}

final class AutoMixV2YandexDownloadClient: YandexMusicDownloadClient, @unchecked Sendable {
    private let metadataStore = AutoMixV2YandexMetadataStore()
    func register(_ metadata: TrackMeta) async { await metadataStore.register(metadata) }
    func metadata(for id: TrackID) async throws -> TrackMeta { try await metadataStore.metadata(for: id) }
    func streamInfo(for id: TrackID) async -> (codec: String, bitrate: Int)? {
        await metadataStore.streamInfo(for: id)
    }
    func downloadOptions(for id: TrackID, forceRefresh: Bool) async throws -> [YandexDownloadOption] {
        _ = forceRefresh
        return try await Task { @MainActor in
            let quality = PlayerCore.shared.audioQuality
            let info = try await YandexMusicService.shared.getStreamInfo(for: id.raw, preferredQuality: quality, preferredBitrate: quality.targetBitrate)
            await self.metadataStore.registerStreamInfo(codec: info.codec, bitrate: info.bitrate, for: id)
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
