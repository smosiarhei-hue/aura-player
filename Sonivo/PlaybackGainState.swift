import Foundation

/// Temporary envelopes only. Idle playback is unity; device volume is owned by iOS.
nonisolated struct PlaybackGainState: Sendable {
    enum Scope: Hashable, Sendable { case wave, sleep }
    private struct Envelope: Sendable { let id: UUID; var gain: Float }
    private var envelopes: [Scope: Envelope] = [:]
    var gain: Float { envelopes.values.reduce(1) { $0 * $1.gain } }
    mutating func begin(_ scope: Scope) -> UUID {
        let id = UUID(); envelopes[scope] = Envelope(id: id, gain: 1); return id
    }
    @discardableResult mutating func update(_ scope: Scope, id: UUID, gain: Float) -> Bool {
        guard envelopes[scope]?.id == id, gain.isFinite else { return false }
        envelopes[scope]?.gain = max(0, min(1, gain)); return true
    }
    @discardableResult mutating func end(_ scope: Scope, id: UUID) -> Bool {
        guard envelopes[scope]?.id == id else { return false }
        envelopes.removeValue(forKey: scope); return true
    }
    mutating func reset(_ scope: Scope) { envelopes.removeValue(forKey: scope) }
    mutating func resetAll() { envelopes.removeAll() }
}
