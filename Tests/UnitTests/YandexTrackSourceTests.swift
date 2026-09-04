// Path: Tests/UnitTests/YandexTrackSourceTests.swift

import Foundation
import MixModels
import Testing
import TrackSource

@Suite("Yandex cached track source")
struct YandexTrackSourceTests {
    @Test("Uses the required MP3 and AAC quality priority")
    func selectsPreferredQuality() throws {
        let options = [
            option(codec: .aac, bitrate: 320),
            option(codec: .mp3, bitrate: 192),
            option(codec: .aac, bitrate: 256),
            option(codec: .mp3, bitrate: 320)
        ]

        let selected = YandexTrackSource.preferredOption(from: options)

        #expect(selected?.codec == .mp3)
        #expect(selected?.bitrateKbps == 320)
    }

    @Test("Reuses the disk cache without requesting download-info again")
    func reusesCachedFile() async throws {
        let fixture = try await Fixture.make(statusCodes: [200])
        defer { fixture.cleanup() }

        let first = try await fixture.source.localFileURL(for: fixture.trackID)
        let second = try await fixture.source.localFileURL(for: fixture.trackID)
        let optionRequests = await fixture.client.optionRequestCount()
        let downloads = await fixture.downloader.downloadCount()

        #expect(first == second)
        #expect(optionRequests == 1)
        #expect(downloads == 1)
    }

    @Test(arguments: [403, 410])
    func refreshesExpiredSignedURLOnce(statusCode: Int) async throws {
        let fixture = try await Fixture.make(statusCodes: [statusCode, 200])
        defer { fixture.cleanup() }

        let file = try await fixture.source.localFileURL(for: fixture.trackID)
        let optionRequests = await fixture.client.optionRequestCount()
        let forcedRefreshes = await fixture.client.forcedRefreshCount()
        let downloads = await fixture.downloader.downloadCount()

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(optionRequests == 2)
        #expect(forcedRefreshes == 1)
        #expect(downloads == 2)
    }
}

private struct Fixture: Sendable {
    let source: YandexTrackSource
    let client: MockYandexClient
    let downloader: MockDownloader
    let trackID: TrackID
    let directory: URL

    static func make(statusCodes: [Int]) async throws -> Fixture {
        let directory = try makeTemporaryDirectory()
        let trackID = TrackID(raw: "100:200")
        let first = option(codec: .mp3, bitrate: 320, suffix: "first")
        let refreshed = option(codec: .mp3, bitrate: 320, suffix: "refreshed")
        let client = MockYandexClient(
            metadata: TrackMeta(
                id: trackID,
                title: "Тестовый трек",
                artist: "Исполнитель",
                albumID: "album",
                durationSec: 180,
                artworkURL: nil
            ),
            firstOptions: [first],
            refreshedOptions: [refreshed]
        )
        let downloader = MockDownloader(statusCodes: statusCodes)
        let cache = try TrackFileCache(directory: directory, capacityBytes: 1_024)
        let source = YandexTrackSource(
            client: client,
            downloader: downloader,
            cache: cache
        )
        return Fixture(
            source: source,
            client: client,
            downloader: downloader,
            trackID: trackID,
            directory: directory
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor MockYandexClient: YandexMusicDownloadClient {
    private let trackMetadata: TrackMeta
    private let firstOptions: [YandexDownloadOption]
    private let refreshedOptions: [YandexDownloadOption]
    private var optionRequests = 0
    private var forcedRefreshes = 0

    init(
        metadata: TrackMeta,
        firstOptions: [YandexDownloadOption],
        refreshedOptions: [YandexDownloadOption]
    ) {
        self.trackMetadata = metadata
        self.firstOptions = firstOptions
        self.refreshedOptions = refreshedOptions
    }

    func metadata(for id: TrackID) -> TrackMeta {
        trackMetadata
    }

    func downloadOptions(for id: TrackID, forceRefresh: Bool) -> [YandexDownloadOption] {
        optionRequests += 1
        if forceRefresh {
            forcedRefreshes += 1
            return refreshedOptions
        }
        return firstOptions
    }

    func optionRequestCount() -> Int {
        optionRequests
    }

    func forcedRefreshCount() -> Int {
        forcedRefreshes
    }
}

private actor MockDownloader: HTTPDownloadClient {
    private var statusCodes: [Int]
    private var downloads = 0

    init(statusCodes: [Int]) {
        self.statusCodes = statusCodes
    }

    func download(from url: URL) throws -> HTTPDownloadResponse {
        downloads += 1
        let status = statusCodes.isEmpty ? 500 : statusCodes.removeFirst()
        let temporaryURL = try makeTemporaryFile(bytes: 32)
        return HTTPDownloadResponse(
            temporaryFileURL: temporaryURL,
            statusCode: status
        )
    }

    func downloadCount() -> Int {
        downloads
    }
}

private func option(
    codec: YandexAudioCodec,
    bitrate: Int,
    suffix: String = UUID().uuidString
) -> YandexDownloadOption {
    YandexDownloadOption(
        url: URL(string: "https://example.com/\(suffix)")!,
        codec: codec,
        bitrateKbps: bitrate,
        fileExtension: codec == .mp3 ? "mp3" : "m4a"
    )
}
