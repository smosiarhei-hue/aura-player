// Path: Packages/AutoMixV2/Sources/TrackSource/TrackFileCache.swift

import Foundation
import MixModels

public actor TrackFileCache {
    public static let defaultCapacityBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private let directory: URL
    private let capacityBytes: Int64
    private let fileManager: FileManager

    public init(directory: URL, capacityBytes: Int64 = TrackFileCache.defaultCapacityBytes,
                fileManager: FileManager = .default) throws {
        self.directory = directory; self.capacityBytes = max(0, capacityBytes); self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw TrackSourceError.fileSystem("Caches directory is unavailable")
        }
        return caches.appendingPathComponent("tracks", isDirectory: true)
    }
    public func fileURL(for id: TrackID, accessedAt: Date = Date()) throws -> URL? {
        guard let url = try matchingFiles(for: id).first else { return nil }
        try? fileManager.setAttributes([.modificationDate: accessedAt], ofItemAtPath: url.path)
        return url
    }
    public func store(temporaryFileURL: URL, for id: TrackID, fileExtension: String,
                      accessedAt: Date = Date()) throws -> URL {
        let ext = sanitizedExtension(fileExtension)
        guard !ext.isEmpty else { throw TrackSourceError.fileSystem("File extension is empty") }
        let destination = directory.appendingPathComponent(encodedFileName(for: id)).appendingPathExtension(ext)
        for existing in try matchingFiles(for: id) where existing != destination { try? fileManager.removeItem(at: existing) }
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: temporaryFileURL)
            try? fileManager.setAttributes([.modificationDate: accessedAt], ofItemAtPath: destination.path)
            return destination
        }
        do { try fileManager.moveItem(at: temporaryFileURL, to: destination) }
        catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: temporaryFileURL)
                return destination
            }
            throw error
        }
        try? fileManager.setAttributes([.modificationDate: accessedAt], ofItemAtPath: destination.path)
        try pruneIfNeeded(); return destination
    }
    public func totalSizeBytes() throws -> Int64 { try entries().reduce(0) { $0 + $1.size } }
    public func pruneIfNeeded() throws {
        var list = try entries().sorted { $0.lastAccess < $1.lastAccess }
        var total = list.reduce(Int64(0)) { $0 + $1.size }
        while total > capacityBytes, let oldest = list.first {
            try? fileManager.removeItem(at: oldest.url); total -= oldest.size; list.removeFirst()
        }
    }
    private func matchingFiles(for id: TrackID) throws -> [URL] {
        let prefix = encodedFileName(for: id) + "."
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles]).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
    private func entries() throws -> [CacheEntry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                   options: [.skipsHiddenFiles]).compactMap { url in
            let v = try url.resourceValues(forKeys: keys); guard v.isRegularFile == true else { return nil }
            return CacheEntry(url: url, size: Int64(v.fileSize ?? 0), lastAccess: v.contentModificationDate ?? .distantPast)
        }
    }
    private func encodedFileName(for id: TrackID) -> String {
        Data(id.raw.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }
    private func sanitizedExtension(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
}
private struct CacheEntry: Sendable { let url: URL; let size: Int64; let lastAccess: Date }
