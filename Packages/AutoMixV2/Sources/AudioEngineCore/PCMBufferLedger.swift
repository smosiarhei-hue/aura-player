// Path: Packages/AutoMixV2/Sources/AudioEngineCore/PCMBufferLedger.swift

import Foundation

/// Value state owned by the engine control queue. A callback may retire a ticket only once
/// and only in the generation in which that buffer was scheduled.
struct PCMBufferLedger: Sendable {
    private(set) var generation = UUID()
    private var tickets: Set<UUID> = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { tickets.count }

    mutating func schedule() -> UUID? {
        guard count < capacity else { return nil }
        let ticket = UUID()
        tickets.insert(ticket)
        return ticket
    }

    mutating func complete(ticket: UUID, generation: UUID) -> Bool {
        guard generation == self.generation else { return false }
        return tickets.remove(ticket) != nil
    }

    mutating func reset() {
        generation = UUID()
        tickets.removeAll(keepingCapacity: true)
    }
}
