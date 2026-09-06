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
    /// Time until the play command completed, not measured hardware output latency.
    public let firstSoundLatencySeconds: Double?
    public let queue: [TrackID]
    public let currentIndex: Int?
    public let preparedIndex: Int?
    public let isTransitioning: Bool
    public let waitingForNext: Bool
    public let lastQueueError: String?

    public init(phase: PlaybackPhase, activeDeck: Deck,
                shouldResumeAfterInterruption: Bool, firstSoundLatencySeconds: Double?,
                queue: [TrackID] = [], currentIndex: Int? = nil, preparedIndex: Int? = nil,
                isTransitioning: Bool = false, waitingForNext: Bool = false,
                lastQueueError: String? = nil) {
        self.phase = phase
        self.activeDeck = activeDeck
        self.shouldResumeAfterInterruption = shouldResumeAfterInterruption
        self.firstSoundLatencySeconds = firstSoundLatencySeconds
        self.queue = queue
        self.currentIndex = currentIndex
        self.preparedIndex = preparedIndex
        self.isTransitioning = isTransitioning
        self.waitingForNext = waitingForNext
        self.lastQueueError = lastQueueError
    }
}

public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
    case noPreparedTrack
}
