import Foundation
import MixModels
import TrackSource

actor AutoMixV2YandexMetadataStore {
    private var values: [TrackID: TrackMeta] = [:]

    func register(_ metadata: TrackMeta) {
        values[metadata.id] = metadata
    }

    func metadata(for id: TrackID) throws -> TrackMeta {
        guard let metadata = values[id] else {
            throw TrackSourceError.metadataUnavailable
        }
        return metadata
    }
}

/// App-side adapter between the existing authenticated Yandex service and the
/// package TrackSource contract. It returns only MP3/AAC options; FLAC and the
/// legacy playback quality setting never enter the AutoMix V2 pipeline.
final class AutoMixV2YandexDownloadClient: YandexMusicDownloadClient, @unchecked Sendable {
    private let metadataStore = AutoMixV2YandexMetadataStore()

    func register(_ metadata: TrackMeta) async {
        await metadataStore.register(metadata)
    }

    func metadata(for id: TrackID) async throws -> TrackMeta {
        try await metadataStore.metadata(for: id)
    }

    func downloadOptions(
        for id: TrackID,
        forceRefresh: Bool
    ) async throws -> [YandexDownloadOption] {
        _ = forceRefresh // getStreamInfo resolves a fresh signed URL on every call.

        return try await Task { @MainActor in
            let info = try await YandexMusicService.shared.getStreamInfo(for: id.raw)
            let codecName = info.codec.lowercased()
            let codec: YandexAudioCodec
            switch codecName {
            case "mp3": codec = .mp3
            case "aac", "he-aac": codec = .aac
            default: throw TrackSourceError.noDownloadOption
            }

            return [YandexDownloadOption(
                url: info.url,
                codec: codec,
                bitrateKbps: info.bitrate,
                fileExtension: codec == .mp3 ? "mp3" : "m4a"
            )]
        }.value
    }
}
