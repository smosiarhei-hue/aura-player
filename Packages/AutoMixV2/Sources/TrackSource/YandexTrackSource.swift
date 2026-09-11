import Foundation
import MixModels

public struct YandexTrackSource: TrackSource, Sendable {
    private let client: any YandexMusicDownloadClient; private let downloader: any HTTPDownloadClient
    private let cache: TrackFileCache; private let downloadGate: DownloadGate
    public init(client: any YandexMusicDownloadClient, downloader: any HTTPDownloadClient = URLSessionDownloadClient(),
                cache: TrackFileCache, maximumParallelDownloads: Int = 2) {
        self.client = client; self.downloader = downloader; self.cache = cache
        downloadGate = DownloadGate(limit: min(2, max(1, maximumParallelDownloads)))
    }
    public func metadata(for id: TrackID) async throws -> TrackMeta { try await client.metadata(for: id) }
    public func localFileURL(for id: TrackID) async throws -> URL {
        guard !id.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TrackSourceError.invalidTrackID }
        if let cached = try await cache.fileURL(for: id) { await DownloadProgressStore.shared.markCached(trackID: id, sizeBytes: nil); return cached }
        return try await downloadGate.withPermit { [client, downloader, cache] in
            if let cached = try await cache.fileURL(for: id) { return cached }
            guard let selected = Self.preferredOption(from: try await client.downloadOptions(for: id, forceRefresh: false)) else { throw TrackSourceError.noDownloadOption }
            return try await Self.download(selected, id: id, retry: true, client: client, downloader: downloader, cache: cache)
        }
    }
    public static func preferredOption(from options: [YandexDownloadOption]) -> YandexDownloadOption? {
        options.min { let l = priority($0), r = priority($1); return l != r ? l < r : $0.bitrateKbps > $1.bitrateKbps }
    }
    private static func priority(_ option: YandexDownloadOption) -> Int {
        switch (option.codec, option.bitrateKbps) { case (.flac, _): 0; case (.mp3, 320...): 1; case (.aac, 256...): 2; case (.aac, 192...): 3; case (.mp3, 192...): 4; default: 5 }
    }
    private static func download(_ option: YandexDownloadOption, id: TrackID, retry: Bool,
                                 client: any YandexMusicDownloadClient, downloader: any HTTPDownloadClient,
                                 cache: TrackFileCache) async throws -> URL {
        await DownloadProgressStore.shared.begin(trackID: id, url: option.url)
        do {
            let response = try await downloader.download(from: option.url)
            switch response.statusCode {
            case 200...299:
                let result = try await cache.store(temporaryFileURL: response.temporaryFileURL, for: id, fileExtension: option.fileExtension)
                await DownloadProgressStore.shared.finish(trackID: id, url: option.url); return result
            case 401: throw TrackSourceError.authenticationRequired
            case 403, 410:
                await DownloadProgressStore.shared.cancel(trackID: id, url: option.url)
                guard retry, let replacement = Self.preferredOption(from: try await client.downloadOptions(for: id, forceRefresh: true)) else { throw TrackSourceError.trackUnavailable }
                return try await download(replacement, id: id, retry: false, client: client, downloader: downloader, cache: cache)
            default: throw TrackSourceError.httpStatus(response.statusCode)
            }
        } catch { await DownloadProgressStore.shared.cancel(trackID: id, url: option.url); throw error }
    }
}
