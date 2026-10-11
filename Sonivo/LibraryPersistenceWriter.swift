import Foundation

/// Metadata only. Bounded latest snapshot per file; encode/write on one utility queue.
/// No audio callback uses this writer. New snapshots and reset/deletion cannot be reordered on disk.
nonisolated final class LibraryPersistenceWriter: @unchecked Sendable {
    static let shared = LibraryPersistenceWriter()
    private struct Job: Sendable { let operation: @Sendable () throws -> Void }
    private let queue = DispatchQueue(label: "sonivo.library.persistence", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: Job] = [:]
    private var scheduled = false
    private var completedWrites = 0
    private var failure: String?
    private let delay: DispatchTimeInterval
    init(delay: DispatchTimeInterval = .milliseconds(120)) { self.delay = delay }

    func write<T: Encodable & Sendable>(_ snapshot: T, to url: URL) {
        enqueue(url: url, job: Job {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        })
    }
    func remove(_ url: URL) {
        enqueue(url: url, job: Job {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        })
    }
    private func enqueue(url: URL, job: Job) {
        lock.lock(); pending[url] = job
        let start = !scheduled; scheduled = true; lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + delay) { [self] in drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let entry = pending.first else { scheduled = false; lock.unlock(); return }
            pending.removeValue(forKey: entry.key); lock.unlock()
            do {
                try entry.value.operation()
                lock.lock(); completedWrites += 1; failure = nil; lock.unlock()
            } catch {
                lock.lock(); failure = error.localizedDescription; lock.unlock()
            }
        }
    }
    /// Asynchronous flush; never wait synchronously on the UI thread.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in drain(); continuation.resume() }
        }
    }
    var diagnostics: (writes: Int, pendingFiles: Int, lastError: String?) {
        lock.lock(); defer { lock.unlock() }
        return (completedWrites, pending.count, failure)
    }
}
