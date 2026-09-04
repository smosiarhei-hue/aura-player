// Path: Tests/UnitTests/TestFileSupport.swift

import Foundation

func makeTestTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeTestTemporaryFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x2A, count: bytes).write(to: url, options: .atomic)
    return url
}

func removeTestItemIfPresent(at url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        assertionFailure("Failed to remove test item: \(error)")
    }
}
