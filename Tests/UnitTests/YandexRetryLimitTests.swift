// Path: Tests/UnitTests/YandexRetryLimitTests.swift

import Foundation
import MixModels
import Testing
import TrackSource

@Suite("Yandex expired URL retry limit")
struct YandexRetryLimitTests {
    @Test(arguments: [403, 410], [403, 410])
    func stopsAfterOneRefresh(firstStatus: Int, secondStatus: Int) async throws {
        let directory = try makeTestTemporaryDirectory()
        defer { removeTestItemIfPresent(at: directory) }
        let id = TrackID(raw: "retry-limit-test")
        let client = RetryLimitClient()
        let downloader = RetryLimitDownloader(
            directory: directory,
            statuses: [firstStatus, secondStatus, 200]
        )
        let cache = try TrackFileCache(
            directory: directory.appendingPathComponent("cache", isDirectory: true)
        )
        let source = YandexTrackSource(client: client, downloader: downloader, cache: cache)

        do {
            _ = try await source.localFileURL(for: id)
            #expect(Bool(false), "A second expired response must not start a third download")
        } catch let error as TrackSourceError {
            #expect(error == .trackUnavailable)
        }

        let downloadCount = await downloader.requestCount()
        let refreshFlags = await client.refreshFlags()
        let cached = try await cache.fileURL(for: id)
        #expect(downloadCount == 2)
        #expect(refreshFlags == [false, true])
        #expect(cached == nil)
    }

    @Test("HTTP 401 is not retried as an expired download URL")
    func authenticationFailureIsNotRetried() async throws {
        let directory = try makeTestTemporaryDirectory()
        defer { removeTestItemIfPresent(at: directory) }
        let client = RetryLimitClient()
        let downloader = RetryLimitDownloader(directory: directory, statuses: [401, 200])
        let cache = try TrackFileCache(
            directory: directory.appendingPathComponent("cache", isDirectory: true)
        )
        let source = YandexTrackSource(client: client, downloader: downloader, cache: cache)

        do {
            _ = try await source.localFileURL(for: TrackID(raw: "unauthorized-test"))
            #expect(Bool(false), "An unauthorized response must require authentication")
        } catch let error as TrackSourceError {
            #expect(error == .authenticationRequired)
        }

        let downloadCount = await downloader.requestCount()
        let refreshFlags = await client.refreshFlags()
        #expect(downloadCount == 1)
        #expect(refreshFlags == [false])
    }
}

private actor RetryLimitClient: YandexMusicDownloadClient {
    private var flags: [Bool] = []

    func metadata(for id: TrackID) throws -> TrackMeta {
        throw TrackSourceError.metadataUnavailable
    }

    func downloadOptions(for id: TrackID, forceRefresh: Bool) throws -> [YandexDownloadOption] {
        flags.append(forceRefresh)
        let url = try #require(URL(string: "https://example.com/retry-test.mp3"))
        return [YandexDownloadOption(url: url, codec: .mp3, bitrateKbps: 320, fileExtension: "mp3")]
    }

    func refreshFlags() -> [Bool] { flags }
}

private actor RetryLimitDownloader: HTTPDownloadClient {
    private let directory: URL
    private let statuses: [Int]
    private var requests = 0

    init(directory: URL, statuses: [Int]) {
        self.directory = directory
        self.statuses = statuses
    }

    func download(from url: URL) throws -> HTTPDownloadResponse {
        let status = requests < statuses.count ? statuses[requests] : 500
        requests += 1
        let temporaryURL = directory.appendingPathComponent("response-\(requests).tmp")
        try Data(repeating: 0x2A, count: 32).write(to: temporaryURL)
        return HTTPDownloadResponse(temporaryFileURL: temporaryURL, statusCode: status)
    }

    func requestCount() -> Int { requests }
}
