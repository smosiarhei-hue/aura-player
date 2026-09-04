// Path: Packages/AutoMixV2/Sources/PlaybackCoordinator/PlaybackState.swift

import Foundation
import MixModels

public enum PlaybackPhase: Sendable, Equatable {
    case idle
    case loading(TrackID)
    case ready(TrackMeta)
    case playing(TrackMeta)
    case paused(TrackMeta)
    case failed(String)
}

public struct PlaybackCoordinatorSnapshot: Sendable, Equatable {
    public let phase: PlaybackPhase
    public let activeDeck: Deck
    public let shouldResumeAfterInterruption: Bool
    public let firstSoundLatencySeconds: Double?

    public init(
        phase: PlaybackPhase,
        activeDeck: Deck,
        shouldResumeAfterInterruption: Bool,
        firstSoundLatencySeconds: Double?
    ) {
        self.phase = phase
        self.activeDeck = activeDeck
        self.shouldResumeAfterInterruption = shouldResumeAfterInterruption
        self.firstSoundLatencySeconds = firstSoundLatencySeconds
    }
}

public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
    case noPreparedTrack
}
