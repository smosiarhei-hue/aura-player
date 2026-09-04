// Path: Tests/UnitTests/LocalTrackSourceTests.swift

import Foundation
import MixModels
import Testing
import TrackSource

@Suite("Local track source")
struct LocalTrackSourceTests {
    @Test("Returns the original local file URL without downloading")
    func returnsRegisteredLocalFile() async throws {
        let id = TrackID(raw: "local-track")
        let fileURL = try makeTestTemporaryFile(bytes: 16)
        defer { removeTestItemIfPresent(at: fileURL) }
        let metadata = TrackMeta(
            id: id,
            title: "Локальный трек",
            artist: "Исполнитель",
            albumID: nil,
            durationSec: 60,
            artworkURL: nil
        )
        let source = LocalTrackSource(
            records: [id: LocalTrackRecord(metadata: metadata, fileURL: fileURL)]
        )

        let resolvedURL = try await source.localFileURL(for: id)
        let resolvedMetadata = try await source.metadata(for: id)

        #expect(resolvedURL == fileURL)
        #expect(resolvedMetadata == metadata)
    }
}
