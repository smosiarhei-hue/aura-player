// Path: Packages/AutoMixV2/Sources/TrackSource/YandexTrackSource.swift

import Foundation
import MixModels

public struct YandexTrackSource: TrackSource, Sendable {
    private let client: any YandexMusicDownloadClient
    private let downloader: any HTTPDownloadClient
    private let cache: TrackFileCache
    private let downloadGate: DownloadGate

    public init(
        client: any YandexMusicDownloadClient,
        downloader: any HTTPDownloadClient = URLSessionDownloadClient(),
        cache: TrackFileCache,
        maximumParallelDownloads: Int = 2
    ) {
        self.client = client
        self.downloader = downloader
        self.cache = cache
        self.downloadGate = DownloadGate(limit: min(2, max(1, maximumParallelDownloads)))
    }

    public func metadata(for id: TrackID) async throws -> TrackMeta {
        try await client.metadata(for: id)
    }

    public func localFileURL(for id: TrackID) async throws -> URL {
        guard !id.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrackSourceError.invalidTrackID
        }
        if let cached = try await cache.fileURL(for: id) {
            return cached
        }

        return try await downloadGate.withPermit { [client, downloader, cache] in
            if let cached = try await cache.fileURL(for: id) {
                return cached
            }
            let options = try await client.downloadOptions(for: id, forceRefresh: false)
            guard let selected = Self.preferredOption(from: options) else {
                throw TrackSourceError.noDownloadOption
            }
            return try await Self.download(
                selected,
                id: id,
                retryAfterExpiredLink: true,
                client: client,
                downloader: downloader,
                cache: cache
            )
        }
    }

    public static func preferredOption(
        from options: [YandexDownloadOption]
    ) -> YandexDownloadOption? {
        options.min { lhs, rhs in
            let lhsRank = priority(for: lhs)
            let rhsRank = priority(for: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.bitrateKbps > rhs.bitrateKbps
        }
    }

    private static func priority(for option: YandexDownloadOption) -> Int {
        switch (option.codec, option.bitrateKbps) {
        case (.mp3, 320...): return 0
        case (.aac, 256...): return 1
        case (.aac, 192...): return 2
        case (.mp3, 192...): return 3
        default: return 4
        }
    }

    private static func download(
        _ option: YandexDownloadOption,
        id: TrackID,
        retryAfterExpiredLink: Bool,
        client: any YandexMusicDownloadClient,
        downloader: any HTTPDownloadClient,
        cache: TrackFileCache
    ) async throws -> URL {
        let response = try await downloader.download(from: option.url)
        switch response.statusCode {
        case 200...299:
            return try await cache.store(
                temporaryFileURL: response.temporaryFileURL,
                for: id,
                fileExtension: option.fileExtension
            )
        case 401:
            throw TrackSourceError.authenticationRequired
        case 403, 410:
            // Apply the retry limit to both statuses, not just the last pattern.
            guard retryAfterExpiredLink else {
                throw TrackSourceError.trackUnavailable
            }
            let refreshed = try await client.downloadOptions(for: id, forceRefresh: true)
            guard let replacement = preferredOption(from: refreshed) else {
                throw TrackSourceError.trackUnavailable
            }
            return try await download(
                replacement,
                id: id,
                retryAfterExpiredLink: false,
                client: client,
                downloader: downloader,
                cache: cache
            )
        default:
            throw TrackSourceError.httpStatus(response.statusCode)
        }
    }
}
