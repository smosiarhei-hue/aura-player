// Path: Tests/UnitTests/TrackFileCacheTests.swift

import Foundation
import MixModels
import Testing
import TrackSource

@Suite("Track file LRU cache")
struct TrackFileCacheTests {
    @Test("Returns a cached file without changing its contents")
    func returnsCachedFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try TrackFileCache(directory: directory, capacityBytes: 1_024)
        let id = TrackID(raw: "42")
        let source = try makeTemporaryFile(bytes: 32)

        let stored = try await cache.store(
            temporaryFileURL: source,
            for: id,
            fileExtension: "mp3"
        )
        let cached = try await cache.fileURL(for: id)

        #expect(cached == stored)
        #expect(FileManager.default.fileExists(atPath: stored.path))
    }

    @Test("Evicts the least recently accessed file when capacity is exceeded")
    func evictsLeastRecentlyUsedFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try TrackFileCache(directory: directory, capacityBytes: 12)
        let oldID = TrackID(raw: "old")
        let newID = TrackID(raw: "new")

        _ = try await cache.store(
            temporaryFileURL: makeTemporaryFile(bytes: 8),
            for: oldID,
            fileExtension: "mp3",
            accessedAt: Date(timeIntervalSince1970: 1)
        )
        _ = try await cache.store(
            temporaryFileURL: makeTemporaryFile(bytes: 8),
            for: newID,
            fileExtension: "aac",
            accessedAt: Date(timeIntervalSince1970: 2)
        )

        let oldFile = try await cache.fileURL(for: oldID)
        let newFile = try await cache.fileURL(for: newID)
        let size = try await cache.totalSizeBytes()

        #expect(oldFile == nil)
        #expect(newFile != nil)
        #expect(size <= 12)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeTemporaryFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x2A, count: bytes).write(to: url, options: .atomic)
    return url
}
