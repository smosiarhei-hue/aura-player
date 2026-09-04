// Path: Packages/AutoMixV2/Sources/AudioEngineCore/AudioEngineModels.swift

import Foundation
import MixModels

public enum AudioEngineCoreError: Error, Sendable, Equatable {
    case unsupportedOutputFormat
    case cannotCreatePCMBuffer
    case cannotCreateConverter
    case conversionFailed(String)
    case deckNotPrepared(Deck)
}

public struct PCMPreloadPolicy: Sendable, Equatable {
    public static let maximumTotalBytes = 25 * 1_024 * 1_024

    public let sampleRate: Double
    public let channels: UInt32
    public let chunkDurationSeconds: Double
    public let queuedDurationPerDeckSeconds: Double

    public init(
        sampleRate: Double = 48_000,
        channels: UInt32 = 2,
        chunkDurationSeconds: Double = 5,
        queuedDurationPerDeckSeconds: Double = 30
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.chunkDurationSeconds = chunkDurationSeconds
        self.queuedDurationPerDeckSeconds = queuedDurationPerDeckSeconds
    }

    public var framesPerChunk: Int {
        Int((sampleRate * chunkDurationSeconds).rounded())
    }

    public var initialChunksPerDeck: Int {
        max(1, Int((queuedDurationPerDeckSeconds / chunkDurationSeconds).rounded(.up)))
    }

    public var estimatedTotalQueuedBytes: Int {
        framesPerChunk * initialChunksPerDeck * Int(channels) * MemoryLayout<Float>.size * 2
    }
}

public struct DeckPlaybackSnapshot: Sendable, Equatable {
    public let deck: Deck
    public let fileURL: URL?
    public let isPrepared: Bool
    public let isPlaying: Bool
    public let gain: Float
    public let queuedChunks: Int
    public let reachedEndOfFile: Bool

    public init(
        deck: Deck,
        fileURL: URL?,
        isPrepared: Bool,
        isPlaying: Bool,
        gain: Float,
        queuedChunks: Int,
        reachedEndOfFile: Bool
    ) {
        self.deck = deck
        self.fileURL = fileURL
        self.isPrepared = isPrepared
        self.isPlaying = isPlaying
        self.gain = gain
        self.queuedChunks = queuedChunks
        self.reachedEndOfFile = reachedEndOfFile
    }
}

public struct AudioEngineSnapshot: Sendable, Equatable {
    public let isRunning: Bool
    public let sampleRate: Double
    public let channels: UInt32
    public let deckA: DeckPlaybackSnapshot
    public let deckB: DeckPlaybackSnapshot

    public init(
        isRunning: Bool,
        sampleRate: Double,
        channels: UInt32,
        deckA: DeckPlaybackSnapshot,
        deckB: DeckPlaybackSnapshot
    ) {
        self.isRunning = isRunning
        self.sampleRate = sampleRate
        self.channels = channels
        self.deckA = deckA
        self.deckB = deckB
    }
}
