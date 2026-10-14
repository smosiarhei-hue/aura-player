import ActivityKit
import Foundation

nonisolated struct SonivoActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        let playbackID: String
        let source: String
        let icon: String
        let accentHex: UInt32
        let isPlaying: Bool
        let elapsed: Double
        let duration: Double
        let timelineStart: Date
        let timelineEnd: Date
    }
    let brand: String
}
