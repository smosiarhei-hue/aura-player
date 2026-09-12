// Path: Packages/AutoMixV2/Sources/MixModels/MixSettings.swift

import Foundation

public enum TransitionMode: String, Sendable, Codable, Equatable {
    case off
    case crossfade
    case automix
}

public struct MixSettings: Sendable, Codable, Equatable {
    public var mode: TransitionMode
    public var crossfadeSeconds: Double
    public var skipTransitionsWithinAlbum: Bool
    public var dontCutEndings: Bool
    public var loudnessNormalization: Bool
    public var targetLUFS: Float

    public init(
        mode: TransitionMode = .automix,
        crossfadeSeconds: Double = 6,
        skipTransitionsWithinAlbum: Bool = true,
        dontCutEndings: Bool = false,
        loudnessNormalization: Bool = true,
        targetLUFS: Float = -14
    ) {
        self.mode = mode
        self.crossfadeSeconds = crossfadeSeconds
        self.skipTransitionsWithinAlbum = skipTransitionsWithinAlbum
        self.dontCutEndings = dontCutEndings
        self.loudnessNormalization = loudnessNormalization
        self.targetLUFS = targetLUFS
    }
}
