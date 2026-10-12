import Foundation

/// Share prefetch/end-of-track work; bounded retries, never a second parallel station start.
@MainActor final class PlaybackContinuationLoader<Key: Equatable & Sendable, Item: Sendable> {
    private var key: Key?
    private var request = UUID()
    private var task: Task<[Item], Never>?
    private let retryDelay: Duration
    init(retryDelay: Duration = .seconds(1)) { self.retryDelay = retryDelay }
    func invalidate() {
        task?.cancel(); task = nil; key = nil; request = UUID()
    }
    func load(key newKey: Key, fetch: @escaping @MainActor () async -> [Item]) async -> [Item] {
        if key == newKey, let task {
            let token = request, result = await task.value
            return request == token && !Task.isCancelled ? result : []
        }
        invalidate(); key = newKey
        let token = request, delay = retryDelay
        let worker = Task { @MainActor in
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return [Item]() }
                let items = await fetch()
                guard !Task.isCancelled else { return [Item]() }
                if !items.isEmpty { return items }
                if attempt < 2 {
                    do { try await Task.sleep(for:delay * (attempt + 1)) } catch { return [Item]() }
                }
            }
            return [Item]()
        }
        task = worker
        let result = await worker.value
        guard request == token, !Task.isCancelled else { return [] }
        task = nil; key = nil
        return result
    }
}
