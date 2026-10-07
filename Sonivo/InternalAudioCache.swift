import Foundation

/// Processing assets are disposable cache, never user-imported library tracks.
nonisolated enum InternalAudioCache {
    static let capacityBytes: Int64 = 256 * 1_024 * 1_024
    static let maximumFileBytes: Int64 = 128 * 1_024 * 1_024
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaybackProcessing", isDirectory: true)
    }

    static func isLegacyFileName(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        guard stem.hasPrefix("vocal_") else { return false }
        return UUID(uuidString: String(stem.dropFirst(6))) != nil
    }

    static func fileURL(for id: UUID) -> URL? {
        let manager = FileManager.default
        let prefix = id.uuidString + "."
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              let file = files.first(where: { $0.lastPathComponent.hasPrefix(prefix) }) else { return nil }
        try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    static func store(temporaryURL: URL, for id: UUID, fileExtension rawExtension: String) throws -> URL {
        let manager = FileManager.default
        let bytes = Int64(try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard bytes > 0, bytes <= maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = rawExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let destination = directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext.isEmpty ? "mp3" : ext)
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: temporaryURL, to: destination)
        prune(excluding: destination)
        return destination
    }

    static func prune(excluding protectedURL: URL?) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for (url, bytes, _) in entries where total > capacityBytes && url != protectedURL {
            do { try manager.removeItem(at: url); total -= bytes } catch { }
        }
    }
}
