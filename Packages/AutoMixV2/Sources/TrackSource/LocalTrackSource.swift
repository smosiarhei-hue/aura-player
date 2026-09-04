// Path: Packages/AutoMixV2/Sources/TrackSource/LocalTrackSource.swift

import Foundation
import MixModels

public struct LocalTrackRecord: Sendable, Equatable {
    public let metadata: TrackMeta
    public let fileURL: URL

    public init(metadata: TrackMeta, fileURL: URL) {
        self.metadata = metadata
        self.fileURL = fileURL
    }
}

public actor LocalTrackSource: TrackSource {
    private var records: [TrackID: LocalTrackRecord]

    public init(records: [TrackID: LocalTrackRecord] = [:]) {
        self.records = records
    }

    public func register(_ record: LocalTrackRecord) {
        records[record.metadata.id] = record
    }

    public func localFileURL(for id: TrackID) throws -> URL {
        guard let record = records[id] else {
            throw TrackSourceError.trackUnavailable
        }
        return record.fileURL
    }

    public func metadata(for id: TrackID) throws -> TrackMeta {
        guard let record = records[id] else {
            throw TrackSourceError.metadataUnavailable
        }
        return record.metadata
    }
}
