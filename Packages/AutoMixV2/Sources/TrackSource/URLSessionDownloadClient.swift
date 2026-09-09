// Path: Packages/AutoMixV2/Sources/TrackSource/URLSessionDownloadClient.swift

@preconcurrency import Foundation

public final class URLSessionDownloadClient: HTTPDownloadClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func download(from url: URL) async throws -> HTTPDownloadResponse {
        let observer = DownloadProgressObserver(url: url)
        let (temporaryURL, response) = try await session.download(for: URLRequest(url: url), delegate: observer)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackSourceError.invalidResponse
        }
        return HTTPDownloadResponse(temporaryFileURL: temporaryURL, statusCode: httpResponse.statusCode)
    }
}

private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    init(url: URL) { self.url = url }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let url = self.url
        Task {
            await DownloadProgressStore.shared.update(url: url,
                                                       receivedBytes: totalBytesWritten,
                                                       totalBytes: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
