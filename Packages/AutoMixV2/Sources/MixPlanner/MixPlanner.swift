// Path: Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift

import Foundation
import MixModels

public enum MixPlanner {
    public static func plan(from a: TrackProfile, to b: TrackProfile,
                            aMeta: TrackMeta, bMeta: TrackMeta,
                            settings: MixSettings) -> TransitionPlan {
        if settings.mode == .off { return none(a: a, reason: "Переходы выключены") }
        if settings.skipTransitionsWithinAlbum, let album = aMeta.albumID,
           album == bMeta.albumID, !a.endsInSilence {
            return none(a: a, reason: "Сохранён непрерывный альбомный переход")
        }
        if a.durationSec < 60 || b.durationSec < 60 {
            return none(a: a, reason: "Трек короче 60 секунд")
        }
        guard settings.mode == .automix else { return crossfade(a, b, settings, "Пользовательский кроссфейд") }
        guard a.mixable, b.mixable, a.confidence.bpm >= 0.7, b.confidence.bpm >= 0.7,
              a.tempoStability >= 0.9, b.tempoStability >= 0.9 else {
            return crossfade(a, b, settings, "Fallback: недостаточная уверенность ритмической сетки")
        }
        guard let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm) else {
            return crossfade(a, b, settings, "Fallback: темпы нельзя безопасно совместить")
        }
        let compatible = CamelotCompatibility.areCompatible(a.camelotKey, b.camelotKey)
        let bars = compatible ? 16.0 : 8.0
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: tempo.targetBPM)
        let out = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let incoming = BeatGridSynchronization.incomingCue(profile: b)
        let gain = normalizationGain(profile: b, settings: settings)
        let fx = [
            FxEvent(target: .a, kind: .volume, startBar: 0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: bars,
                    fromValue: -60, toValue: 0, curve: .sCurve)
        ]
        return TransitionPlan(type: compatible ? .beatmatchedLong : .beatmatchedShort,
                              aOutStartSec: out, bInStartSec: incoming, bars: bars,
                              tempoTargetBPM: tempo.targetBPM, rateA: tempo.rateA, rateB: tempo.rateB,
                              gainOffsetBdB: gain, loopBarsA: 0, fx: fx,
                              reason: compatible ? "Beatmatch: совместимые фразы и Camelot" : "Beatmatch: короткий безопасный переход")
    }

    private static func crossfade(_ a: TrackProfile, _ b: TrackProfile,
                                  _ settings: MixSettings, _ reason: String) -> TransitionPlan {
        let seconds = min(12, max(1, settings.crossfadeSeconds))
        let start = min(max(0, a.mixOutSec), max(0, a.durationSec - seconds))
        return TransitionPlan(type: .crossfade, aOutStartSec: start,
                              bInStartSec: max(0, b.mixInSec), bars: seconds,
                              tempoTargetBPM: 0, rateA: 1, rateB: 1,
                              gainOffsetBdB: normalizationGain(profile: b, settings: settings),
                              loopBarsA: 0,
                              fx: [FxEvent(target: .a, kind: .volume, startBar: 0, endBar: seconds, fromValue: 0, toValue: -60, curve: .sCurve),
                                   FxEvent(target: .b, kind: .volume, startBar: 0, endBar: seconds, fromValue: -60, toValue: 0, curve: .sCurve)],
                              reason: reason)
    }

    private static func none(a: TrackProfile, reason: String) -> TransitionPlan {
        TransitionPlan(type: .none, aOutStartSec: a.durationSec, bInStartSec: 0,
                       bars: 0, tempoTargetBPM: 0, rateA: 1, rateB: 1,
                       gainOffsetBdB: 0, loopBarsA: 0, fx: [], reason: reason)
    }

    private static func normalizationGain(profile: TrackProfile, settings: MixSettings) -> Float {
        settings.loudnessNormalization ? min(12, max(-12, settings.targetLUFS - profile.integratedLUFS)) : 0
    }
}

public enum BeatGridSynchronization {
    public struct TempoMatch: Sendable, Equatable {
        public let targetBPM: Float
        public let rateA: Float
        public let rateB: Float
    }

    public static func tempoMatch(aBPM: Float, bBPM: Float, maximumRateChange: Float = 0.08) -> TempoMatch? {
        guard aBPM.isFinite, bBPM.isFinite, aBPM > 30, bBPM > 30 else { return nil }
        var b = bBPM
        while b / aBPM > 1.5 { b /= 2 }
        while aBPM / b > 1.5 { b *= 2 }
        let target = sqrt(aBPM * b)
        let rateA = target / aBPM, rateB = target / b
        guard abs(rateA - 1) <= maximumRateChange, abs(rateB - 1) <= maximumRateChange else { return nil }
        return TempoMatch(targetBPM: target, rateA: rateA, rateB: rateB)
    }

    public static func duration(bars: Double, bpm: Float) -> Double {
        guard bpm > 0 else { return 0 }
        return bars * 4 * 60 / Double(bpm)
    }

    public static func outgoingCue(profile: TrackProfile, duration: Double) -> Double {
        let latest = min(profile.mixOutSec, max(0, profile.durationSec - duration))
        return profile.phraseStartsSec.last(where: { $0 <= latest })
            ?? profile.downbeatsSec.last(where: { $0 <= latest }) ?? latest
    }

    public static func incomingCue(profile: TrackProfile) -> Double {
        profile.phraseStartsSec.first(where: { $0 >= profile.mixInSec })
            ?? profile.downbeatsSec.first(where: { $0 >= profile.mixInSec }) ?? profile.mixInSec
    }

    public static func phaseErrorMilliseconds(outgoingBeat: Double, incomingBeat: Double,
                                               rateA: Float, rateB: Float) -> Double {
        abs(outgoingBeat / Double(rateA) - incomingBeat / Double(rateB)) * 1_000
    }
}

public enum CamelotCompatibility {
    public static func areCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let a = parse(lhs), let b = parse(rhs) else { return false }
        if a == b { return true }
        if a.number == b.number, a.letter != b.letter { return true }
        if a.letter == b.letter {
            let distance = abs(a.number - b.number)
            return distance == 1 || distance == 11
        }
        return false
    }
    private static func parse(_ value: String?) -> (number: Int, letter: Character)? {
        guard let value, let letter = value.last, letter == "A" || letter == "B",
              let number = Int(value.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter)
    }
}
