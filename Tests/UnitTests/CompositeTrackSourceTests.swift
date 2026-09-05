// Path: Tests/UnitTests/CompositeTrackSourceTests.swift

import Foundation
import MixModels
import Testing
import TrackSource

@Suite("Composite track source")
struct CompositeTrackSourceTests {
    @Test("Routes local and Yandex tracks without replacing the coordinator source")
    func routesBothSources() async throws {
        let localID = TrackID(raw: "local-track")
        let yandexID = TrackID(raw: "123456")
        let localURL = try makeTestTemporaryFile(bytes: 8)
        let yandexURL = try makeTestTemporaryFile(bytes: 16)
        defer {
            removeTestItemIfPresent(at: localURL)
            removeTestItemIfPresent(at: yandexURL)
        }

        let localMeta = TrackMeta(
            id: localID,
            title: "Local",
            artist: "Artist",
            albumID: nil,
            durationSec: 60,
            artworkURL: nil
        )
        let yandexMeta = TrackMeta(
            id: yandexID,
            title: "Yandex",
            artist: "Artist",
            albumID: "album",
            durationSec: 180,
            artworkURL: nil
        )

        let local = LocalTrackSource(records: [
            localID: LocalTrackRecord(metadata: localMeta, fileURL: localURL)
        ])
        let yandex = LocalTrackSource(records: [
            yandexID: LocalTrackRecord(metadata: yandexMeta, fileURL: yandexURL)
        ])
        let source = CompositeTrackSource(localSource: local, yandexSource: yandex)

        await source.register(localID, route: .local)
        await source.register(yandexID, route: .yandex)

        #expect(try await source.localFileURL(for: localID) == localURL)
        #expect(try await source.metadata(for: localID) == localMeta)
        #expect(try await source.localFileURL(for: yandexID) == yandexURL)
        #expect(try await source.metadata(for: yandexID) == yandexMeta)
        #expect(await source.route(for: localID) == .local)
        #expect(await source.route(for: yandexID) == .yandex)
    }

    @Test("Rejects tracks that were not registered")
    func rejectsUnknownTrack() async {
        let source = CompositeTrackSource(
            localSource: LocalTrackSource(),
            yandexSource: LocalTrackSource()
        )

        await #expect(throws: TrackSourceError.metadataUnavailable) {
            _ = try await source.metadata(for: TrackID(raw: "unknown"))
        }
    }
}
