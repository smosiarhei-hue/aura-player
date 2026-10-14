import Foundation

/// No audio/session ownership. A checkpoint restores metadata paused, never playback intent.
nonisolated enum PlaybackResumePolicy {
    static func position(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let value = max(0, seconds)
        return duration.isFinite && duration > 0 ? min(value, duration) : value
    }
    static func queueRange(count: Int, currentIndex: Int?) -> Range<Int> {
        let start = min(max(0, (currentIndex ?? 0) - 5), max(0, count - 1))
        return start..<min(count, start + 60)
    }
}

/// Skip a broken Wave source, but never churn indefinitely during a network outage.
nonisolated struct WavePlaybackRecovery {
    private(set) var failedIDs = Set<String>()
    private var context: String?
    private var consecutive = 0
    mutating func prepare(context: String) {
        if self.context != context { self = Self(); self.context = context }
    }
    mutating func fail(_ id: String) -> Bool {
        guard !id.isEmpty, failedIDs.insert(Self.key(id)).inserted else { return false }
        consecutive += 1
        return consecutive <= 5
    }
    func excludes(_ id: String) -> Bool { failedIDs.contains(Self.key(id)) }
    mutating func heard(seconds: Double) {
        if seconds.isFinite && seconds >= 2 { consecutive = 0 }
    }
    static func key(_ id: String) -> String {
        String(id.split(separator: ":", maxSplits: 1).first ?? Substring(id))
    }
}
