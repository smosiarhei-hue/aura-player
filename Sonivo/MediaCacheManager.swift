import Foundation
import Observation

@Observable
@MainActor
final class MediaCacheManager {
    static let shared = MediaCacheManager()

    private(set) var totalBytes: Int64 = 0
    private(set) var isRefreshing = false
    private(set) var isClearing = false

    private init() {}

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        totalBytes = await Task.detached(priority: .utility) {
            Self.calculateCacheSize()
        }.value
        isRefreshing = false
    }

    func clearGeneratedCache() async {
        guard !isClearing else { return }
        isClearing = true
        await Task.detached(priority: .utility) {
            Self.removeGeneratedCache()
        }.value
        totalBytes = 0
        isClearing = false
    }

    nonisolated private static var cacheDirectories: [URL] {
        let manager = FileManager.default
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let temporary = manager.temporaryDirectory
        return [
            caches.appendingPathComponent("tracks", isDirectory: true),
            caches.appendingPathComponent("ArtworkCache", isDirectory: true),
            documents.appendingPathComponent("AIVideoShots", isDirectory: true),
            temporary.appendingPathComponent("profiles", isDirectory: true),
            temporary.appendingPathComponent("neuromix-profiles", isDirectory: true)
        ]
    }

    nonisolated private static var temporaryAudioFiles: [URL] {
        let manager = FileManager.default
        return (try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("ym_") || name.hasPrefix("stream_")
        } ?? []
    }

    nonisolated private static func calculateCacheSize() -> Int64 {
        let manager = FileManager.default
        var total: Int64 = 0

        for directory in cacheDirectories {
            guard let enumerator = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }

        for file in temporaryAudioFiles {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }

        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? manager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.lastPathComponent.hasPrefix("vocal_") {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true {
                    total += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return total
    }

    nonisolated private static func removeGeneratedCache() {
        let manager = FileManager.default
        for directory in cacheDirectories {
            try? manager.removeItem(at: directory)
        }
        for file in temporaryAudioFiles {
            try? manager.removeItem(at: file)
        }

        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? manager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("vocal_") {
            try? manager.removeItem(at: file)
        }
    }
}