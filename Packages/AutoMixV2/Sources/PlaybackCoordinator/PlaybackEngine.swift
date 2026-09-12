// Path: Packages/AutoMixV2/Sources/PlaybackCoordinator/PlaybackEngine.swift

import AudioEngineCore
import Foundation
import MixModels

/// Injectable boundary. Implementations serialize all graph mutations themselves.
public protocol PlaybackEngine: Sendable {
    func prepare(_ deck: Deck, fileURL: URL, startTimeSeconds: Double) async throws
    func play(_ deck: Deck) async throws
    func pause(_ deck: Deck) async
    func resume(_ deck: Deck) async throws
    func stop(_ deck: Deck) async
    func stopEngine() async
    func setGain(_ gain: Float, for deck: Deck) async
    func skip(from current: Deck, to next: Deck) async throws
    func crossfade(from outgoing: Deck, to incoming: Deck, durationSeconds: Double) async throws
    func snapshot() async -> AudioEngineSnapshot
}

extension DualDeckAudioEngine: PlaybackEngine {}
