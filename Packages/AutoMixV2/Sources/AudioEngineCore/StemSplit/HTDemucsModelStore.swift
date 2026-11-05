import Foundation

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (Double) -> Void = { _ in }
    func set(_ handler: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }
    func call(_ value: Double) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler(value)
    }
}

public struct HTDemucsModelError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Downloads the FP32 HTDemucs `.mlpackage` (drums, bass, other, vocals) into Application Support.
/// The weights are about 400 MB, so the first AutoMix on a phone waits on Wi-Fi once.
public actor HTDemucsModelStore {
    public static let shared = HTDemucsModelStore()

    private static let manifestBytes: Int64 = 617
    private static let modelBytes: Int64 = 1_476_469
    private static let weightBytes: Int64 = 423_198_848
    private static let origin = "https://huggingface.co/pkurzok/htdemucs-coreml/resolve/main/"

    private let downloader = HTDemucsFileDownloader()
    private let progress = ProgressBox()
    private var inflight: Task<URL, Error>?

    public nonisolated func installedPackageURL() -> URL? {
        let root = Self.packageRoot()
        guard Self.fileSize(root.appendingPathComponent("Manifest.json")) == Self.manifestBytes,
              Self.fileSize(root.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")) == Self.modelBytes,
              Self.fileSize(root.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")) == Self.weightBytes
        else { return nil }
        return root
    }

    public func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        progress.set(onProgress)
        if let installed = installedPackageURL() {
            onProgress(1)
            return installed
        }
        if let inflight {
            return try await inflight.value
        }
        let box = progress
        let task = Task { try await self.downloadAll(onProgress: { box.call($0) }) }
        inflight = task
        do {
            let url = try await task.value
            inflight = nil
            return url
        } catch {
            inflight = nil
            throw error
        }
    }

    private func downloadAll(onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let root = Self.packageRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        if free > 0, free < 900_000_000 {
            throw HTDemucsModelError("мало места на iPhone")
        }
        let files: [(String, Int64, Double, Double)] = [
            ("Manifest.json", Self.manifestBytes, 0, 0.002),
            ("Data/com.apple.CoreML/model.mlmodel", Self.modelBytes, 0.002, 0.01),
            ("Data/com.apple.CoreML/weights/weight.bin", Self.weightBytes, 0.012, 0.988)
        ]
        for (relative, bytes, base, span) in files {
            try Task.checkCancellation()
            guard let remote = URL(string: Self.origin + relative) else {
                throw HTDemucsModelError("битая ссылка модели")
            }
            let dest = root.appendingPathComponent(relative)
            try await downloader.fetch(
                remote: remote,
                dest: dest,
                expected: bytes,
                base: base,
                span: span,
                onProgress: onProgress
            )
        }
        guard let installed = installedPackageURL() else {
            throw HTDemucsModelError("модель скачалась не целиком")
        }
        onProgress(1)
        return installed
    }

    private static func packageRoot() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HTDemucs/htdemucs.mlpackage", isDirectory: true)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? -1
    }
}

final class HTDemucsFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let lock = NSLock()
    private var pending: Pending?

    private final class Gate {
        private let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?
        private var resumed = false
        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard !resumed, let continuation else {
                lock.unlock()
                return
            }
            resumed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    private struct Pending {
        var dest: URL
        var expected: Int64
        var resumeURL: URL
        var gate: Gate
        var onProgress: @Sendable (Double) -> Void
        var base: Double
        var span: Double
        var task: URLSessionDownloadTask
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 40
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func fetch(
        remote: URL,
        dest: URL,
        expected: Int64,
        base: Double,
        span: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if Self.size(dest) == expected {
            onProgress(base + span)
            return
        }
        let resumeURL = dest.appendingPathExtension("resume")
        let resumeData = try? Data(contentsOf: resumeURL)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task: URLSessionDownloadTask
                if let resumeData, !resumeData.isEmpty {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: remote)
                }
                let gate = Gate()
                gate.continuation = continuation
                let item = Pending(
                    dest: dest,
                    expected: expected,
                    resumeURL: resumeURL,
                    gate: gate,
                    onProgress: onProgress,
                    base: base,
                    span: span,
                    task: task
                )
                lock.lock()
                pending = item
                lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let task = self.pending?.task
            self.lock.unlock()
            task?.cancel(byProducingResumeData: { data in
                if let data { try? data.write(to: resumeURL) }
            })
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let item = pending
        lock.unlock()
        guard let item else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : item.expected
        let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : 0
        item.onProgress(item.base + item.span * fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let item = pending
        lock.unlock()
        guard let item else { return }
        do {
            let folder = item.dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: item.dest.path) {
                try FileManager.default.removeItem(at: item.dest)
            }
            try FileManager.default.moveItem(at: location, to: item.dest)
            let got = Self.size(item.dest)
            guard got == item.expected else {
                try? FileManager.default.removeItem(at: item.dest)
                throw HTDemucsModelError("файл модели \(got) байт, ждали \(item.expected)")
            }
            try? FileManager.default.removeItem(at: item.resumeURL)
            item.gate.finish(.success(()))
            lock.lock()
            pending = nil
            lock.unlock()
        } catch {
            item.gate.finish(.failure(error))
            lock.lock()
            pending = nil
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            lock.lock()
            let resumeURL = pending?.resumeURL
            lock.unlock()
            if let resumeURL { try? data.write(to: resumeURL) }
        }
        lock.lock()
        let gate = pending?.gate
        pending = nil
        lock.unlock()
        if ns.code == NSURLErrorCancelled {
            gate?.finish(.failure(CancellationError()))
        } else {
            gate?.finish(.failure(error))
        }
    }

    private static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }
}
