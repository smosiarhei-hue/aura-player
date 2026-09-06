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
        chunkDurationSeconds: Double = 10,
        queuedDurationPerDeckSeconds: Double = 30
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.chunkDurationSeconds = chunkDurationSeconds
        self.queuedDurationPerDeckSeconds = queuedDurationPerDeckSeconds
    }

    public var framesPerChunk: Int {
        let value = (sampleRate * chunkDurationSeconds).rounded()
        guard value.isFinite, value > 0, value < Double(Int.max) else { return 0 }
        return Int(value)
    }

    public var initialChunksPerDeck: Int {
        guard chunkDurationSeconds > 0 else { return 0 }
        let value = (queuedDurationPerDeckSeconds / chunkDurationSeconds).rounded(.up)
        guard value.isFinite, value > 0, value < Double(Int.max) else { return 0 }
        return Int(value)
    }

    public var estimatedTotalQueuedBytes: Int {
        var total = framesPerChunk
        for factor in [initialChunksPerDeck, Int(channels), MemoryLayout<Float>.size, 2] {
            let product = total.multipliedReportingOverflow(by: factor)
            guard !product.overflow else { return Int.max }
            total = product.partialValue
        }
        return total
    }

    public var isValid: Bool {
        sampleRate == 48_000 && channels == 2
            && chunkDurationSeconds.isFinite && chunkDurationSeconds > 0
            && queuedDurationPerDeckSeconds.isFinite
            && queuedDurationPerDeckSeconds >= chunkDurationSeconds
            && queuedDurationPerDeckSeconds <= 30
            && framesPerChunk > 0 && initialChunksPerDeck > 0
            && estimatedTotalQueuedBytes <= Self.maximumTotalBytes
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
    public let lastError: String?

    public init(
        deck: Deck,
        fileURL: URL?,
        isPrepared: Bool,
        isPlaying: Bool,
        gain: Float,
        queuedChunks: Int,
        reachedEndOfFile: Bool,
        lastError: String? = nil
    ) {
        self.deck = deck
        self.fileURL = fileURL
        self.isPrepared = isPrepared
        self.isPlaying = isPlaying
        self.gain = gain
        self.queuedChunks = queuedChunks
        self.reachedEndOfFile = reachedEndOfFile
        self.lastError = lastError
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
