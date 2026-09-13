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
        if a.durationSec < 45 || b.durationSec < 45 {
            return none(a: a, reason: "Трек короче 45 секунд")
        }
        guard settings.mode == .automix else { return crossfade(a, b, settings, "Пользовательский кроссфейд") }
        guard (a.mixable || a.confidence.bpm >= 0.40), (b.mixable || b.confidence.bpm >= 0.40) else {
            return filterEchoPlan(from: a, to: b, settings: settings, reason: "DJ Filter Sweep (недостаточная сетка)")
        }

        // 1. Match Tempos with DJ dynamic pitch fader logic (octaves, direct & mutual sync)
        guard let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm) else {
            return filterEchoPlan(from: a, to: b, settings: settings, reason: "DJ Filter + Echo Out (темпы слишком далеки)")
        }

        let compatible = CamelotCompatibility.areCompatible(a.camelotKey, b.camelotKey)

        // 2. Determine Bars: 16 bars for high confidence/compatible, 12 or 8 bars otherwise. Never rushed 4 bars!
        var bars: Double
        if compatible {
            bars = (a.confidence.bpm >= 0.60 && b.confidence.bpm >= 0.60) ? 16.0 : 12.0
        } else {
            bars = (a.confidence.bpm >= 0.60 && b.confidence.bpm >= 0.60) ? 12.0 : 8.0
        }

        // Check how much outro time is available in Track A
        let durationAtBars = BeatGridSynchronization.duration(bars: bars, bpm: tempo.targetBPM)
        let availableOutro = max(0, a.durationSec - a.mixOutSec)
        if availableOutro < durationAtBars && bars > 8.0 {
            let durationAt8 = BeatGridSynchronization.duration(bars: 8.0, bpm: tempo.targetBPM)
            if availableOutro >= durationAt8 || a.durationSec > 60 {
                bars = 8.0
            }
        }

        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: tempo.targetBPM)

        // 3. Perfect Cue Snapping: snap both cues to exact downbeats so phase difference is 0 ms!
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut

        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let finalType: TransitionType = (bars >= 16 && compatible) ? .beatmatchedLong : .beatmatchedShort
        return TransitionPlan(type: finalType,
                              aOutStartSec: out, bInStartSec: incoming, bars: bars,
                              tempoTargetBPM: tempo.targetBPM, rateA: tempo.rateA, rateB: tempo.rateB,
                              gainOffsetBdB: normalizationGain(profile: b, settings: settings),
                              loopBarsA: 0, fx: stage4FX(bars: bars, tempo: tempo, compatible: compatible),
                              reason: compatible
                                ? "Beatmatch + Camelot (\(a.camelotKey ?? "?") -> \(b.camelotKey ?? "?"))"
                                : "Beatmatch (\(Int(round(a.bpm))) -> \(Int(round(b.bpm))) @ \(Int(round(tempo.targetBPM))) BPM)")
    }

    private static func stage4FX(bars: Double,
                                 tempo: BeatGridSynchronization.TempoMatch,
                                 compatible: Bool) -> [FxEvent] {
        let half = max(2.0, bars / 2.0)
        let bassCutStart = max(0, half - 1.5)
        let bassCutEnd = half
        let bassDropStart = half
        let bassDropEnd = min(bars, half + 1.0)
        let echoStart = max(0, half - 1.0)

        var events = [
            // Outgoing volume fades over the second half
            FxEvent(target: .a, kind: .volume, startBar: half * 0.5, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            // Incoming volume rises smoothly into the drop
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: half,
                    fromValue: -40, toValue: 0, curve: .sCurve),

            // Bass Swap: Outgoing bass cuts smoothly right before the drop
            FxEvent(target: .a, kind: .bassKill, startBar: bassCutStart, endBar: bassCutEnd,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            // Incoming bass is muted during buildup
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: bassDropStart,
                    fromValue: 1, toValue: 1, curve: .linear),
            // Incoming bass DROPS on the downbeat!
            FxEvent(target: .b, kind: .bassOn, startBar: bassDropStart, endBar: bassDropEnd,
                    fromValue: 1, toValue: 0, curve: .sCurve),

            // High-Pass on outgoing sweeps mud and bass away, keeping vocals clean
            FxEvent(target: .a, kind: .highPass, startBar: 0, endBar: bars,
                    fromValue: 20, toValue: compatible ? 4500 : 3200, curve: .exp),
            // Low-Pass on incoming sweeps open into the drop
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: half,
                    fromValue: 1200, toValue: 20000, curve: .exp),

            // Rate ramp: smoothly returns Track B to 1.0 over the final 2-3 bars
            FxEvent(target: .b, kind: .rateRamp, startBar: max(0, bars - 2), endBar: bars,
                    fromValue: tempo.rateB, toValue: 1, curve: .sCurve)
        ]

        // Echo Out wash on outgoing track during and after the drop
        events.append(FxEvent(target: .a, kind: .echoOut,
                              startBar: echoStart, endBar: bars,
                              fromValue: 0, toValue: compatible ? 65 : 55,
                              curve: .sCurve, param: 48))

        return events
    }

    private static func filterEchoPlan(from a: TrackProfile, to b: TrackProfile,
                                       settings: MixSettings, reason: String) -> TransitionPlan {
        let bars = 10.0 // 10 full bars (~18-20s, NOT rushed 4 bars / 7s!)
        let targetBPM: Float = a.bpm > 30 ? a.bpm : (b.bpm > 30 ? b.bpm : 120.0)
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let events: [FxEvent] = [
            FxEvent(target: .a, kind: .volume, startBar: 4.0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: 5.0,
                    fromValue: -40, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .bassKill, startBar: 3.0, endBar: 5.0,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: 5.0,
                    fromValue: 1, toValue: 1, curve: .linear),
            FxEvent(target: .b, kind: .bassOn, startBar: 5.0, endBar: 6.0,
                    fromValue: 1, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .highPass, startBar: 0, endBar: bars,
                    fromValue: 20, toValue: 4500, curve: .exp),
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: 5.0,
                    fromValue: 1000, toValue: 20000, curve: .exp),
            FxEvent(target: .a, kind: .echoOut, startBar: 3.0, endBar: bars,
                    fromValue: 0, toValue: 65, curve: .sCurve, param: 52)
        ]
        return TransitionPlan(
            type: .filterEcho,
            aOutStartSec: out,
            bInStartSec: incoming,
            bars: bars,
            tempoTargetBPM: targetBPM,
            rateA: 1.0,
            rateB: 1.0,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0,
            fx: events,
            reason: reason
        )
    }

    private static func crossfade(_ a: TrackProfile, _ b: TrackProfile,
                                  _ settings: MixSettings, _ reason: String) -> TransitionPlan {
        let seconds = min(16, max(6, settings.crossfadeSeconds))
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
    public static func tempoMatch(aBPM: Float, bBPM: Float, maximumRateChange: Float = 0.16) -> TempoMatch? {
        guard aBPM.isFinite, bBPM.isFinite, aBPM > 30, bBPM > 30 else { return nil }

        // Find the best octave / multiple for B (1x, 0.5x half-time, 2x double-time)
        var candidates: [Float] = [bBPM, bBPM * 2.0, bBPM * 0.5]
        if bBPM > 175 { candidates.append(bBPM / 2.0) }
        if bBPM < 75 { candidates.append(bBPM * 2.0) }

        // Pick candidate closest to aBPM
        let bBest = candidates.min(by: { abs($0 - aBPM) < abs($1 - aBPM) }) ?? bBPM

        // 1. Direct match: only Track B adjusts if within 8%
        let directRatio = aBPM / bBest
        if abs(directRatio - 1.0) <= 0.08 {
            return TempoMatch(targetBPM: aBPM, rateA: 1.0, rateB: directRatio)
        }

        // 2. Mutual match: A and B meet at target tempo (geometric mean)
        // e.g. 115 vs 128 -> target 121.3 BPM. rateA = 0.948 (-5.2%), rateB = 1.055 (+5.5%).
        let targetBPM = sqrt(aBPM * bBest)
        let rateA = targetBPM / aBPM
        let rateB = targetBPM / bBest

        let maxShift = max(abs(rateA - 1.0), abs(rateB - 1.0))
        if maxShift <= maximumRateChange {
            return TempoMatch(targetBPM: targetBPM, rateA: rateA, rateB: rateB)
        }

        // 3. Direct shift up to 16% on Track B alone if Track A is at natural tempo
        if abs(directRatio - 1.0) <= 0.16 {
            return TempoMatch(targetBPM: aBPM, rateA: 1.0, rateB: directRatio)
        }

        return nil
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
