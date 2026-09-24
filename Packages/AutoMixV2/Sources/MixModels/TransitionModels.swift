// Path: Packages/AutoMixV2/Sources/MixModels/TransitionModels.swift

import Foundation

public enum TransitionType: String, Sendable, Codable, Equatable {
    case beatmatchedLong
    case beatmatchedShort
    case hardCut
    case filterEcho
    case crossfade
    case none
}

public enum Curve: String, Sendable, Codable, Equatable {
    case linear
    case exp
    case sCurve
}

public enum FxKind: String, Sendable, Codable, Equatable {
    case highPass
    case lowPass
    case bassKill
    case bassOn
    case echoOut
    case reverbWash
    case tapeStop
    case stutter
    case volume
    case rateRamp
    case vocalDucking
}

public enum Deck: String, Sendable, Codable, Equatable {
    case a
    case b
}

public struct FxEvent: Sendable, Codable, Equatable {
    public let target: Deck
    public let kind: FxKind
    public let startBar: Double
    public let endBar: Double
    public let fromValue: Float
    public let toValue: Float
    public let curve: Curve
    public let param: Float?

    public init(
        target: Deck,
        kind: FxKind,
        startBar: Double,
        endBar: Double,
        fromValue: Float,
        toValue: Float,
        curve: Curve,
        param: Float? = nil
    ) {
        self.target = target
        self.kind = kind
        self.startBar = startBar
        self.endBar = endBar
        self.fromValue = fromValue
        self.toValue = toValue
        self.curve = curve
        self.param = param
    }
}

public enum MixTransitionArchetype: String, Sendable, Codable, Equatable {
    case dropSwap     // Сведение в дроп (для House, EDM, Hip-Hop с ровной бочкой)
    case echoFreeze   // Удар эха с резким входом (при разнице BPM > 15% или несовместимых тональностях)
    case tapeStop     // Виниловый стоп (колесо диджея) перед дропом
    case beatStutter  // Ритмичное заикание 1/16 перед дропом
    case spaceReverb  // Космический реверб wash
    case energyWash   // Равномощностный кроссфейд + HPF (для поп/рок музыки без явной сетки)
    case seamlessLoop // Длинное мэшап-сведение на 16-32 такта (при одинаковом BPM и ключе)
}

public struct TransitionPlan: Sendable, Codable, Equatable {
    public let type: TransitionType
    public let archetype: MixTransitionArchetype
    public let aOutStartSec: Double
    public let bInStartSec: Double
    public let bars: Double
    public let tempoTargetBPM: Float
    public let rateA: Float
    public let rateB: Float
    public let pitchShiftCentsB: Float
    public let gainOffsetBdB: Float
    public let loopBarsA: Int
    public let fx: [FxEvent]
    public let reason: String

    public init(
        type: TransitionType,
        archetype: MixTransitionArchetype = .energyWash,
        aOutStartSec: Double,
        bInStartSec: Double,
        bars: Double,
        tempoTargetBPM: Float,
        rateA: Float,
        rateB: Float,
        pitchShiftCentsB: Float = 0,
        gainOffsetBdB: Float,
        loopBarsA: Int,
        fx: [FxEvent],
        reason: String
    ) {
        self.type = type
        self.archetype = archetype
        self.aOutStartSec = aOutStartSec
        self.bInStartSec = bInStartSec
        self.bars = bars
        self.tempoTargetBPM = tempoTargetBPM
        self.rateA = rateA
        self.rateB = rateB
        self.pitchShiftCentsB = pitchShiftCentsB
        self.gainOffsetBdB = gainOffsetBdB
        self.loopBarsA = loopBarsA
        self.fx = fx
        self.reason = reason
    }
}
