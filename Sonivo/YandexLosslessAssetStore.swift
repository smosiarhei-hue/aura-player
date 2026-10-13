import Foundation
import AVFoundation

/// Disposable, account-scoped decoded media. No OAuth, file URLs, or AES keys are saved in metadata.
actor YandexLosslessAssetStore {
    nonisolated enum Failure: Error { case invalidURL, badResponse, invalidAudio, cacheFull }
    private let session: URLSession
    private let downloadOverride: (@Sendable (URL) async throws -> (URL, URLResponse))?
    private let directory: URL
    private var ready: [String: URL] = [:]
    private var downloads = 0
    private let capacityBytes: Int64 = 512 * 1_024 * 1_024

    init(session: URLSession? = nil, directory: URL? = nil,
         downloadOverride: (@Sendable (URL) async throws -> (URL, URLResponse))? = nil) {
        self.downloadOverride = downloadOverride
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        self.session = session ?? URLSession(configuration: configuration)
        // Only our UUID-namespaced temporary folders are removed on a fresh app session.
        if directory == nil { Self.removeStaleTemporaryDirectories() }
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("SonivoLossless-" + UUID().uuidString, isDirectory: true)
    }

    func materialize(url: URL, keyHex: String, codec: String, trackID: String, account: UUID,
                     protectedURLs: @Sendable () async -> Set<URL>) async throws -> URL {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw Failure.invalidURL }
        guard ["flac", "flac-mp4"].contains(codec.lowercased()) else { throw Failure.invalidAudio }
        _ = try YandexEncrawDecryptor.keyBytes(keyHex)
        try Task.checkCancellation()
        let cacheKey = account.uuidString + ":" + trackID + ":" + codec.lowercased()
        if let cached = ready[cacheKey], FileManager.default.fileExists(atPath: cached.path) { return cached }
        while downloads >= 2 { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        downloads += 1
        defer { downloads -= 1 }
        if let cached = ready[cacheKey], FileManager.default.fileExists(atPath: cached.path) { return cached }
        // Async URLSession download owns cancellation and its temporary ciphertext; no custom task delegates.
        let downloaded: (URL, URLResponse)
        if let downloadOverride { downloaded = try await downloadOverride(url) }
        else { downloaded = try await session.download(from: url) }
        let (encrypted, response) = downloaded
        defer { try? FileManager.default.removeItem(at: encrypted) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https" else { throw Failure.badResponse }
        let size = Int64(try encrypted.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0, size <= YandexEncrawDecryptor.maximumFileBytes else { throw YandexEncrawDecryptor.Failure.invalidSize }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = codec.lowercased() == "flac-mp4" ? "m4a" : "flac"
        let decoded = directory.appendingPathComponent(account.uuidString + "-" + UUID().uuidString).appendingPathExtension(ext)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: decoded) } }
        let job = Task.detached(priority: .userInitiated) {
            try YandexEncrawDecryptor.decryptFile(encrypted, to: decoded, keyHex: keyHex)
        }
        try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
        try Task.checkCancellation()
        try await Self.validateDecodedAudio(decoded, codec: codec)
        let protected = await protectedURLs()
        try Task.checkCancellation()
        try prune(protecting: protected.union([decoded]))
        ready[cacheKey] = decoded; completed = true
        return decoded
    }

    nonisolated static func validateDecodedAudio(_ url: URL, codec: String) async throws {
        if codec.lowercased() == "flac" {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC else { throw Failure.invalidAudio }
        } else if codec.lowercased() == "flac-mp4" {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else { throw Failure.invalidAudio }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw Failure.invalidAudio }
            let formats = try await track.load(.formatDescriptions)
            guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatFLAC }) else { throw Failure.invalidAudio }
        } else { throw Failure.invalidAudio }
    }

    private func prune(protecting protected: Set<URL>) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(Int64(0)) { $0 + $1.1 }
        for (url, bytes, _) in entries where size > capacityBytes && !protected.contains(url) {
            try FileManager.default.removeItem(at: url); size -= bytes
            ready = ready.filter { $0.value != url }
        }
        guard size <= capacityBytes else { throw Failure.cacheFull }
    }

    nonisolated static var temporaryDirectories: [URL] {
        let manager = FileManager.default
        return (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
            let prefix = "SonivoLossless-"
            guard $0.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String($0.lastPathComponent.dropFirst(prefix.count))) != nil else { return false }
            return (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []
    }
    nonisolated static func removeStaleTemporaryDirectories() {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
    }

    func discard(_ url: URL) {
        guard url.deletingLastPathComponent() == directory else { return }
        ready = ready.filter { $0.value != url }; try? FileManager.default.removeItem(at: url)
    }
}
