// Path: Sonivo/DJAutoMixEngine/DJMixModels.swift
import Foundation
import AVFoundation

extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

nonisolated public struct StructureSegment: Equatable, Sendable, Codable {
    public let range: Range<TimeInterval>
    public let energy: Double     // 0...1
    public let isVocal: Bool

    public init(range: Range<TimeInterval>, energy: Double, isVocal: Bool) {
        self.range = range
        self.energy = max(0.0, min(1.0, energy))
        self.isVocal = isVocal
    }
}

nonisolated public struct DJTrackAnalysis: Equatable, Sendable, Codable {
    public let trackID: UUID
    public let bpm: Double
    public let key: CamelotKey
    public let beatGrid: [TimeInterval]       // тайминги долей от начала трека
    public let structure: [StructureSegment]
    public let leadInSilence: TimeInterval
    public let trailingSilence: TimeInterval
    public let confidence: Double             // 0...1 — насколько доверяем анализу

    public init(
        trackID: UUID,
        bpm: Double,
        key: CamelotKey,
        beatGrid: [TimeInterval],
        structure: [StructureSegment],
        leadInSilence: TimeInterval,
        trailingSilence: TimeInterval,
        confidence: Double
    ) {
        self.trackID = trackID
        self.bpm = bpm
        self.key = key
        self.beatGrid = beatGrid
        self.structure = structure
        self.leadInSilence = max(0.0, leadInSilence)
        self.trailingSilence = max(0.0, trailingSilence)
        self.confidence = max(0.0, min(1.0, confidence))
    }
}

nonisolated public enum FadeCurve: String, Codable, Sendable, Equatable {
    case linear
    case equalPower
    case sCurve
    case djMashup
}

nonisolated public enum EQBand: String, Codable, Sendable, Equatable {
    case lowShelf
    case midPeaking
    case highShelf
}

nonisolated public struct EQKeyframe: Equatable, Sendable, Codable {
    public let time: TimeInterval
    public let band: EQBand
    public let gainDB: Float
    public let duration: TimeInterval

    public init(time: TimeInterval, band: EQBand, gainDB: Float, duration: TimeInterval) {
        self.time = time
        self.band = band
        self.gainDB = gainDB
        self.duration = duration
    }
}

nonisolated public struct DJMixPlan: Equatable, Sendable {
    public let duration: TimeInterval
    public let outgoingExitPoint: TimeInterval
    public let incomingEntryPoint: TimeInterval
    public let tempoRatio: Double            // во сколько раз растягиваем incoming
    public let volumeCurve: FadeCurve
    public let eqAutomation: [EQKeyframe]    // напр. duck low-shelf у уходящего трека

    public init(
        duration: TimeInterval,
        outgoingExitPoint: TimeInterval,
        incomingEntryPoint: TimeInterval,
        tempoRatio: Double,
        volumeCurve: FadeCurve = .djMashup,
        eqAutomation: [EQKeyframe] = []
    ) {
        self.duration = duration
        self.outgoingExitPoint = outgoingExitPoint
        self.incomingEntryPoint = incomingEntryPoint
        self.tempoRatio = tempoRatio
        self.volumeCurve = volumeCurve
        self.eqAutomation = eqAutomation
    }
}

nonisolated public enum DJTransitionType: Equatable, Sendable {
    case hardCut
    case simpleCrossfade(duration: TimeInterval)
    case djStyleMix(DJMixPlan)
}

nonisolated public enum DJAutoMix {
    public typealias TrackAnalysis = DJTrackAnalysis
    public typealias TransitionType = DJTransitionType
    public typealias MixPlan = DJMixPlan
    public typealias Key = CamelotKey
}
