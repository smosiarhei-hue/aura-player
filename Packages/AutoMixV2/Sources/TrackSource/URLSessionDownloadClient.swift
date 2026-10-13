// Path: Packages/AutoMixV2/Sources/TrackSource/URLSessionDownloadClient.swift

import Foundation

/// Uses the system async download implementation. A custom per-task delegate
/// was deliberately removed because it could outlive the playback request and
/// crash during cancellation on physical devices.
public final class URLSessionDownloadClient: HTTPDownloadClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func download(from url: URL) async throws -> HTTPDownloadResponse {
        if url.isFileURL {
            try Task.checkCancellation()
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: url, to: temporaryURL)
                try Task.checkCancellation()
                return HTTPDownloadResponse(temporaryFileURL: temporaryURL, statusCode: 200)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL); throw error
            }
        }
        let (temporaryURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackSourceError.invalidResponse
        }
        return HTTPDownloadResponse(temporaryFileURL: temporaryURL,
                                    statusCode: httpResponse.statusCode)
    }
}
