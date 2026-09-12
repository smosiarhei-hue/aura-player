import Foundation
import MixModels

public struct TrackDownloadProgress: Sendable, Equatable {
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let fraction: Double?
    public let isDownloading: Bool

    public init(receivedBytes: Int64, totalBytes: Int64?, isDownloading: Bool) {
        let received = max(0, receivedBytes)
        let expected = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        self.receivedBytes = received
        self.totalBytes = expected
        self.fraction = expected.map { min(1, max(0, Double(received) / Double($0))) }
        self.isDownloading = isDownloading
    }
}

public actor DownloadProgressStore {
    public static let shared = DownloadProgressStore()
    private var urlToTrack: [URL: TrackID] = [:]
    private var values: [TrackID: TrackDownloadProgress] = [:]

    public func begin(trackID: TrackID, url: URL) {
        urlToTrack[url] = trackID
        values[trackID] = TrackDownloadProgress(receivedBytes: 0, totalBytes: nil, isDownloading: true)
    }
    public func update(url: URL, receivedBytes: Int64, totalBytes: Int64) {
        guard let id = urlToTrack[url] else { return }
        values[id] = TrackDownloadProgress(receivedBytes: receivedBytes,
                                           totalBytes: totalBytes > 0 ? totalBytes : nil,
                                           isDownloading: true)
    }
    public func finish(trackID: TrackID, url: URL) {
        let previous = values[trackID]
        let total = previous?.totalBytes ?? previous?.receivedBytes
        values[trackID] = TrackDownloadProgress(receivedBytes: total ?? 0,
                                                totalBytes: total,
                                                isDownloading: false)
        urlToTrack[url] = nil
    }
    public func cancel(trackID: TrackID, url: URL) {
        values[trackID] = nil
        urlToTrack[url] = nil
    }
    public func markCached(trackID: TrackID, sizeBytes: Int64? = nil) {
        values[trackID] = TrackDownloadProgress(receivedBytes: sizeBytes ?? 0,
                                                totalBytes: sizeBytes,
                                                isDownloading: false)
    }
    public func snapshot(for trackID: TrackID) -> TrackDownloadProgress? { values[trackID] }
}
