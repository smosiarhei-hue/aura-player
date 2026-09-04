// Path: Packages/AutoMixV2/Sources/TrackSource/URLSessionDownloadClient.swift

import Foundation

public final class URLSessionDownloadClient: HTTPDownloadClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(from url: URL) async throws -> HTTPDownloadResponse {
        let (temporaryURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackSourceError.invalidResponse
        }
        return HTTPDownloadResponse(
            temporaryFileURL: temporaryURL,
            statusCode: httpResponse.statusCode
        )
    }
}
