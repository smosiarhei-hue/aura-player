import Foundation

nonisolated struct VideoShotLoadKey: Equatable {
    let trackID: UUID?
    let playbackTrackID: UUID?
    let enabled: Bool
    let reduceMotion: Bool
    let accountGeneration: UUID
}

nonisolated enum VideoShotPlaybackPolicy {
    static func shouldPlay(enabled: Bool, ready: Bool, matchingTrack: Bool,
                           musicPlaying: Bool, sceneActive: Bool, playerVisible: Bool,
                           lyricsVisible: Bool, reduceMotion: Bool) -> Bool {
        enabled && ready && matchingTrack && musicPlaying && sceneActive &&
        playerVisible && !lyricsVisible && !reduceMotion
    }
}
