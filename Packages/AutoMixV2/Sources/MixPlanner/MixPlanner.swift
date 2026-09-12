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
        guard a.mixable, b.mixable else { return crossfade(a, b, settings, "Fallback: трек не предназначен для сведения") }
        guard let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm) else {
            return crossfade(a, b, settings, "Fallback: темпы нельзя безопасно совместить")
        }
        let compatible = CamelotCompatibility.areCompatible(a.camelotKey, b.camelotKey)
        var bars: Double
        if a.confidence.bpm >= 0.85, b.confidence.bpm >= 0.85, a.tempoStability >= 0.9, b.tempoStability >= 0.9 {
            bars = compatible ? 16.0 : 8.0
        } else if a.confidence.bpm >= 0.70, b.confidence.bpm >= 0.70, a.tempoStability >= 0.85, b.tempoStability >= 0.85 {
            bars = compatible ? 8.0 : 4.0
        } else if a.confidence.bpm >= 0.55, b.confidence.bpm >= 0.55, a.tempoStability >= 0.75, b.tempoStability >= 0.75 {
            bars = 4.0
        } else {
            return crossfade(a, b, settings, "Fallback: недостаточная уверенность ритмической сетки")
        }
        var seconds = BeatGridSynchronization.duration(bars: bars, bpm: tempo.targetBPM)
        var out = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let incoming = BeatGridSynchronization.incomingCue(profile: b)
        let phaseA = a.downbeatsSec.min(by: { abs($0 - out) < abs($1 - out) }).map { abs(out - $0) } ?? 0
        let phaseB = b.downbeatsSec.min(by: { abs($0 - b.mixInSec) < abs($1 - b.mixInSec) }).map { abs(b.mixInSec - $0) } ?? 0
        let phaseError = BeatGridSynchronization.phaseErrorMilliseconds(outgoingBeat: phaseA, incomingBeat: phaseB, rateA: tempo.rateA, rateB: tempo.rateB)
        if phaseError > 80 {
            return crossfade(a, b, settings, "Fallback: фазовое расхождение > 80ms")
        } else if phaseError > 40 {
            bars = max(4.0, bars / 2)
            seconds = BeatGridSynchronization.duration(bars: bars, bpm: tempo.targetBPM)
            out = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        }
        let finalType: TransitionType = (bars >= 16 && compatible) ? .beatmatchedLong : .beatmatchedShort
        return TransitionPlan(type: finalType,
                              aOutStartSec: out, bInStartSec: incoming, bars: bars,
                              tempoTargetBPM: tempo.targetBPM, rateA: tempo.rateA, rateB: tempo.rateB,
                              gainOffsetBdB: normalizationGain(profile: b, settings: settings),
                              loopBarsA: 0, fx: stage4FX(bars: bars, tempo: tempo, compatible: compatible),
                              reason: compatible ? "Beatmatch + Camelot + filter/bass/echo automation" : "Beatmatch + short filter automation")
    }

    private static func stage4FX(bars: Double,
                                 tempo: BeatGridSynchronization.TempoMatch,
                                 compatible: Bool) -> [FxEvent] {
        var events = [
            FxEvent(target: .a, kind: .volume, startBar: 0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .linear),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: bars,
                    fromValue: -60, toValue: 0, curve: .linear),
            FxEvent(target: .a, kind: .bassKill, startBar: 0, endBar: 2,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: 0,
                    fromValue: 1, toValue: 1, curve: .linear),
            FxEvent(target: .b, kind: .bassOn, startBar: 2, endBar: 3,
                    fromValue: 1, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .highPass, startBar: 0, endBar: bars,
                    fromValue: 20, toValue: compatible ? 4500 : 2500, curve: .exp),
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: 2,
                    fromValue: 1200, toValue: 20000, curve: .exp),
            FxEvent(target: .b, kind: .rateRamp, startBar: max(0, bars - 1), endBar: bars,
                    fromValue: tempo.rateB, toValue: 1, curve: .sCurve)
        ]
        if compatible {
            events.append(FxEvent(target: .a, kind: .echoOut,
                                  startBar: max(0, bars - 4), endBar: bars,
                                  fromValue: 0, toValue: 65, curve: .sCurve, param: 50))
        }
        return events
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
                              fx: [FxEvent(target: .a, kind: .volume, startBar: 0, endBar: seconds, fromValue: 0, toValue: -60, curve: .linear),
                                   FxEvent(target: .b, kind: .volume, startBar: 0, endBar: seconds, fromValue: -60, toValue: 0, curve: .linear)],
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
    public struct TempoMatch: Sendable, Equatable { public let targetBPM: Float; public let rateA: Float; public let rateB: Float }
    public static func tempoMatch(aBPM: Float, bBPM: Float, maximumRateChange: Float = 0.08) -> TempoMatch? {
        guard aBPM.isFinite, bBPM.isFinite, aBPM > 30, bBPM > 30 else { return nil }
        var b = bBPM; while b / aBPM > 1.5 { b /= 2 }; while aBPM / b > 1.5 { b *= 2 }
        let target = aBPM, rateA: Float = 1.0, rateB = aBPM / b
        guard abs(rateB - 1) <= maximumRateChange else { return nil }
        return TempoMatch(targetBPM: target, rateA: rateA, rateB: rateB)
    }
    public static func duration(bars: Double, bpm: Float) -> Double { bpm > 0 ? bars * 240 / Double(bpm) : 0 }
    public static func outgoingCue(profile: TrackProfile, duration: Double) -> Double {
        let latest = min(profile.mixOutSec, max(0, profile.durationSec - duration))
        if let downbeat = profile.downbeatsSec.last(where: { $0 <= latest }) {
            if let phrase = profile.phraseStartsSec.last(where: { $0 <= latest }) {
                let beat = profile.bpm > 0 ? 60.0 / Double(profile.bpm) : 0.5
                if let matched = profile.downbeatsSec.min(by: { abs($0 - phrase) < abs($1 - phrase) }),
                   abs(matched - phrase) <= beat {
                    return matched
                }
            }
            return downbeat
        }
        return profile.phraseStartsSec.last(where: { $0 <= latest }) ?? latest
    }
    public static func incomingCue(profile: TrackProfile) -> Double {
        if let firstDownbeat = profile.downbeatsSec.first(where: { $0 >= profile.mixInSec }) {
            let fourBars = profile.bpm > 0 ? 16.0 * 60.0 / Double(profile.bpm) : 8.0
            if let firstPhrase = profile.phraseStartsSec.first(where: { $0 >= profile.mixInSec }),
               firstPhrase - profile.mixInSec <= fourBars {
                let beat = profile.bpm > 0 ? 60.0 / Double(profile.bpm) : 0.5
                if let matched = profile.downbeatsSec.min(by: { abs($0 - firstPhrase) < abs($1 - firstPhrase) }),
                   abs(matched - firstPhrase) <= beat {
                    return matched
                }
            }
            return firstDownbeat
        }
        return profile.phraseStartsSec.first(where: { $0 >= profile.mixInSec }) ?? profile.mixInSec
    }
    public static func phaseErrorMilliseconds(outgoingBeat: Double, incomingBeat: Double, rateA: Float, rateB: Float) -> Double {
        abs(outgoingBeat / Double(rateA) - incomingBeat / Double(rateB)) * 1_000
    }
}

public enum CamelotCompatibility {
    public static func areCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let a = parse(lhs), let b = parse(rhs) else { return false }
        if a == b || (a.number == b.number && a.letter != b.letter) { return true }
        if a.letter == b.letter { let d = abs(a.number - b.number); return d == 1 || d == 11 }
        return false
    }
    private static func parse(_ value: String?) -> (number: Int, letter: Character)? {
        guard let value, let letter = value.last, letter == "A" || letter == "B",
              let number = Int(value.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter)
    }
}
