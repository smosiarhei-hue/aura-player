import Foundation

/// A restored queue or paused metadata must not take back another app's media card.
/// Only successful playback activation creates ownership. Other audio/interruption
/// yields it until a new explicit playback request succeeds.
nonisolated struct SonivoPlaybackOwnership: Sendable {
    private(set) var hasPlaybackIntent = false
    private(set) var interrupted = false
    mutating func activated() { hasPlaybackIntent = true; interrupted = false }
    mutating func yield() { hasPlaybackIntent = false }
    mutating func interruptionBegan() { interrupted = true; yield() }
    mutating func interruptionEnded() { interrupted = false }
    mutating func allowsPublication(otherAudioPlaying: Bool) -> Bool {
        if otherAudioPlaying { yield() }
        return hasPlaybackIntent && !interrupted
    }
    static func mayResume(systemShouldResume: Bool, wasPlaying: Bool, otherAudioPlaying: Bool) -> Bool {
        systemShouldResume && wasPlaying && !otherAudioPlaying
    }
}

nonisolated enum SonivoExternalPlaybackRoute {
    static func accepts(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["sonivo", "aurora"].contains(scheme),
              url.user == nil, url.password == nil, url.port == nil else { return false }
        let path = url.path.split(separator: "/")
        switch url.host?.lowercased() {
        case "player": return path.isEmpty
        case "track": return path.count == 1 && UUID(uuidString: String(path[0])) != nil
        default: return false
        }
    }
}
