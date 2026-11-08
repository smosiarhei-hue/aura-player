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
        if settings.mode == .duet {
            return planDuet(from: a, to: b, aMeta: aMeta, bMeta: bMeta, settings: settings)
        }
        guard settings.mode == .automix else { return crossfade(a, b, settings, "Пользовательский кроссфейд") }

        guard a.mixable, b.mixable else {
            return crossfade(a, b, settings, "Fallback: трек не предназначен для сведения")
        }

        // Existing confidence is a coarse heuristic, not a calibrated proof of
        // beat phase. Decline tempo/loop effects for obviously uncertain grids.
        guard a.bpm.isFinite, b.bpm.isFinite,
              a.confidence.bpm >= 0.70, b.confidence.bpm >= 0.70,
              a.confidence.downbeats >= 0.65, b.confidence.downbeats >= 0.65,
              !a.downbeatsSec.isEmpty, !b.downbeatsSec.isEmpty else {
            return crossfade(a, b, settings, "Fallback: недостаточно надёжная сетка")
        }

        // ±1 semitone max for Automix — ±200¢ TimePitch sounded cheap/dirty in field 1055.
        let harmonic = CamelotCompatibility.match(a.camelotKey, b.camelotKey, maxSemitones: 1)
        let bpmDiffPct: Float = (a.bpm > 30 && b.bpm > 30) ? abs(a.bpm - b.bpm) / a.bpm : 1.0

        // 1. Оценка уверенности сетки и выбор длины перехода по DJ Confidence Ladder (8-16 тактов)
        var ladderBars: Double
        if a.confidence.bpm >= 0.80, b.confidence.bpm >= 0.80, a.tempoStability >= 0.85, b.tempoStability >= 0.85 {
            ladderBars = harmonic.isNaturallyCompatible ? 16.0 : 8.0
        } else {
            ladderBars = 8.0
        }

        // Подбор темпа через динамический питч-фейдер
        guard let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm) else {
            // A long natural-rate mashup here cannot hold a common beat. Do not
            // apply rhythmic FX or stem separation to an unalignable pair.
            // PlayerCore routes this plan to the neutral, short safe fade.
            return crossfade(a, b, settings, "Fallback: темпы нельзя безопасно совместить")
        }

        // Проверка фазового расхождения сетки
        let testDuration = BeatGridSynchronization.duration(bars: ladderBars, bpm: tempo.targetBPM)
        let testOut = BeatGridSynchronization.outgoingCue(profile: a, duration: testDuration)
        let testIn = BeatGridSynchronization.incomingCue(profile: b)
        // Preserve phase sign: equally distant cues on opposite sides of a beat
        // are not in sync. Missing grids are unknown, not a zero-error match.
        guard let beatA = a.downbeatsSec.filter({ $0.isFinite }).min(by: { abs($0 - testOut) < abs($1 - testOut) }),
              let beatB = b.downbeatsSec.filter({ $0.isFinite }).min(by: { abs($0 - testIn) < abs($1 - testIn) }) else {
            return crossfade(a, b, settings, "Fallback: нет надёжной сетки долей")
        }
        let phaseA = testOut - beatA
        let phaseB = testIn - beatB
        let phaseError = BeatGridSynchronization.phaseErrorMilliseconds(outgoingBeat: phaseA, incomingBeat: phaseB, rateA: tempo.rateA, rateB: tempo.rateB)
        if phaseError > 120 {
            return crossfade(a, b, settings, "Fallback: фазовое расхождение > 120ms")
        }

        let availableOutro = max(0, a.durationSec - a.mixOutSec)
        let bpmClose = bpmDiffPct <= 0.08
        let bpmFar = bpmDiffPct > 0.08
        let bpmVeryFar = bpmDiffPct > 0.12
        let energyOut = meanTail(a.energyCurve) ?? 0.5
        let energyIn = meanHead(b.energyCurve) ?? 0.5
        let energyJump = energyIn - energyOut
        let hasIncomingDrop = b.dropsSec.contains { $0 >= 6 && $0 <= 48 }

        // TZ §2.4: BPM·Key·outro·energy → distinct per-pair archetype (never one cookie-cutter).
        // FX palette: seamlessLoop (phrase loop + soft delay), spaceReverb (plate wash),
        // echoFreeze (tempo delay), beatStutter (1/16 gate) — musical DualDeck FX only.
        let archetype: MixTransitionArchetype
        if (bpmFar && !harmonic.isHarmonicallyViable) || (bpmVeryFar && !harmonic.isNaturallyCompatible) {
            archetype = .echoFreeze
        } else if availableOutro > 0 && availableOutro < 14 {
            archetype = .echoFreeze
        } else if ladderBars >= 16.0 && availableOutro >= 36 && bpmClose && harmonic.isNaturallyCompatible && a.confidence.bpm >= 0.80 {
            archetype = .seamlessLoop
        } else if harmonic.isNaturallyCompatible && bpmClose && energyJump >= 0.22 && hasIncomingDrop {
            // Hot drop ahead → stutter into the hit (unique vs plain dropSwap).
            archetype = .beatStutter
            ladderBars = min(ladderBars, 8.0)
        } else if harmonic.isNaturallyCompatible && bpmClose && energyOut >= 0.65 && energyJump <= -0.18 {
            // Energy cliff → vinyl brake before soft B.
            archetype = .tapeStop
            ladderBars = min(ladderBars, 4.0)
        } else if harmonic.isNaturallyCompatible && bpmClose
                    && energyOut >= 0.38 && energyOut <= 0.62
                    && abs(energyJump) <= 0.14 && !hasIncomingDrop
                    && availableOutro >= 18 {
            // Even mid-energy pair → plate wash (smooth space, not a drop hit).
            archetype = .spaceReverb
            ladderBars = min(12.0, max(8.0, ladderBars))
        } else if harmonic.isNaturallyCompatible && bpmClose {
            archetype = .dropSwap
        } else if harmonic.isHarmonicallyViable && bpmDiffPct <= 0.1 {
            archetype = energyJump >= 0.18 && hasIncomingDrop ? .beatStutter : .dropSwap
            if archetype == .beatStutter { ladderBars = min(ladderBars, 8.0) }
        } else if bpmClose && !harmonic.isNaturallyCompatible {
            // Ключи конфликтуют, но темп лочится → Echo Out с beatmatch (не 6-bar snap).
            archetype = .echoFreeze
        } else {
            archetype = bpmFar ? .echoFreeze : .energyWash
        }

        switch archetype {
        case .seamlessLoop:
            return planSeamlessLoop(from: a, to: b, tempo: tempo, settings: settings, harmonic: harmonic)
        case .dropSwap:
            return planDropSwap(from: a, to: b, bars: ladderBars, tempo: tempo, settings: settings, harmonic: harmonic)
        case .beatStutter:
            return planBeatStutter(from: a, to: b, bars: min(8.0, max(4.0, ladderBars)), tempo: tempo, settings: settings, harmonic: harmonic)
        case .tapeStop:
            return planTapeStop(from: a, to: b, bars: min(4.0, max(2.0, ladderBars)), settings: settings, harmonic: harmonic)
        case .echoFreeze:
            return planEchoFreeze(from: a, to: b, tempo: tempo, settings: settings, harmonic: harmonic)
        case .spaceReverb:
            return planSpaceReverb(from: a, to: b, bars: ladderBars, tempo: tempo, settings: settings, harmonic: harmonic)
        case .energyWash:
            return planEnergyWash(from: a, to: b, settings: settings, harmonic: harmonic)
        }
    }

    /// Modern Adaptive Phrase Duet (Lab `oneBarDuet`).
    /// Quality gate: beatmatch ±18% + Camelot ±3 semitones, else Automix fallback.
    private static func planDuet(from a: TrackProfile, to b: TrackProfile,
                                 aMeta: TrackMeta, bMeta: TrackMeta,
                                 settings: MixSettings) -> TransitionPlan {
        guard a.mixable, b.mixable else {
            return crossfade(a, b, settings, "Duet → crossfade: трек не для сведения")
        }

        let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm, maximumRateChange: 0.18)
        let harmonic = CamelotCompatibility.match(a.camelotKey, b.camelotKey, maxSemitones: 3)

        if tempo == nil || !harmonic.isHarmonicallyViable {
            // Soft Duet: still dual-vocal window with content cues — never ONE VOCAL Automix.
            // Planner adapts length/cues; rates stay natural when the grid cannot lock.
            let why: [String] = [
                tempo == nil ? "BPM far" : nil,
                !harmonic.isHarmonicallyViable ? harmonic.description : nil
            ].compactMap { $0 }
            return planSoftDuet(
                from: a, to: b, settings: settings,
                tempo: tempo, harmonic: harmonic,
                note: why.joined(separator: " · ")
            )
        }

        let bpm = tempo!.targetBPM
        let energyOut = meanTail(a.energyCurve) ?? 0.5
        let energyIn = meanHead(b.energyCurve) ?? 0.5
        let energyShift = abs(energyIn - energyOut)
        let archetype: MixTransitionArchetype =
            (energyShift >= 0.18 || energyIn >= 0.62) ? .energyWash : .dropSwap

        // Content-aware 2–12 bars; prefer 4–8 for vocal→vocal.
        let barSec = 240.0 / Double(max(60, bpm))
        let minBlend = max(4.0, barSec * 2)
        let maxBlend = min(28.0, max(minBlend, barSec * 12))
        let cueA = BeatGridSynchronization.outgoingCue(profile: a, duration: minBlend)
        let available = max(minBlend, a.durationSec - cueA)
        let room = min(maxBlend, available)
        var bestBars = 6.0
        var bestScore = -1.0
        for bars in stride(from: 2.0, through: 12.0, by: 2.0) {
            let sec = bars * barSec
            guard sec >= minBlend - 0.05, sec <= room + 0.05 else { continue }
            let lengthBias = (bars >= 4 && bars <= 8) ? 0.2 : (bars == 2 ? 0.02 : (bars <= 10 ? 0.06 : -0.05))
            let score = lengthBias + (bars == 6 ? 0.05 : 0)
            if score > bestScore {
                bestScore = score
                bestBars = bars
            }
        }
        var blendSec = min(room, max(minBlend, bestBars * barSec))
        var outCue = a.downbeatsSec.min(by: { abs($0 - cueA) < abs($1 - cueA) }) ?? cueA
        if a.durationSec - outCue < blendSec {
            outCue = BeatGridSynchronization.outgoingCue(profile: a, duration: blendSec)
            blendSec = min(blendSec, max(minBlend, a.durationSec - outCue))
        }
        let bars = max(2.0, blendSec / barSec)
        let handoffAt = 0.68
        let bassSwapAt = max(0.14, handoffAt - 0.22)
        let handoffBar = bars * handoffAt
        let bassBar = bars * bassSwapAt
        let pitched = abs(harmonic.pitchShiftCents) >= 80
        let cents = max(-300, min(300, harmonic.pitchShiftCents))

        let events: [FxEvent] = [
            FxEvent(target: .a, kind: .volume, startBar: 0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: min(2, bars * 0.35),
                    fromValue: -18, toValue: 0, curve: .sCurve),
            // ONE BASS: kill A early, open B at swap.
            FxEvent(target: .a, kind: .bassKill, startBar: 0, endBar: bassBar,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: 0,
                    fromValue: 1, toValue: 1, curve: .linear),
            FxEvent(target: .b, kind: .bassOn, startBar: bassBar, endBar: min(bars, bassBar + 1),
                    fromValue: 1, toValue: 0, curve: .sCurve),
            // Duet: keep A vocal (no instrumentalize); soft mid-duck on B during stack.
            FxEvent(target: .b, kind: .vocalDucking, startBar: 0, endBar: handoffBar,
                    fromValue: pitched ? -7 : -5, toValue: 0, curve: .sCurve),
            // Audible LAND FX — LPF invite on B, HPF + echo on A.
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: min(2.5, bars * 0.4),
                    fromValue: archetype == .energyWash ? 900 : 1100, toValue: 20_000, curve: .exp),
            FxEvent(target: .a, kind: .highPass, startBar: max(0, handoffBar - 0.5), endBar: bars,
                    fromValue: 20, toValue: 4800, curve: .exp),
            FxEvent(target: .a, kind: .echoOut, startBar: max(0, handoffBar), endBar: bars,
                    fromValue: 0, toValue: archetype == .energyWash ? 55 : 48, curve: .sCurve, param: 50),
            FxEvent(target: .b, kind: .rateRamp, startBar: max(0, bars - 1), endBar: bars,
                    fromValue: tempo!.rateB, toValue: 1, curve: .sCurve)
        ]

        let rawIn = BeatGridSynchronization.incomingCue(profile: b, duration: blendSec)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIn) < abs($1 - rawIn) }) ?? rawIn

        return TransitionPlan(
            type: .beatmatchedShort,
            archetype: archetype,
            aOutStartSec: outCue,
            bInStartSec: incoming,
            bars: bars,
            tempoTargetBPM: bpm,
            rateA: tempo!.rateA,
            rateB: tempo!.rateB,
            pitchShiftCentsB: cents,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0,
            fx: events,
            reason: "DUET · \(Int(round(bars))) bars · vocal A + vocal B · instr B · LAND · \(harmonic.description)"
        )
    }

    /// Content-aware Duet when hard tempo/key lock is unavailable.
    private static func planSoftDuet(
        from a: TrackProfile, to b: TrackProfile,
        settings: MixSettings,
        tempo: BeatGridSynchronization.TempoMatch?,
        harmonic: HarmonicMatch,
        note: String
    ) -> TransitionPlan {
        let bpm: Float = tempo?.targetBPM
            ?? (a.bpm > 30 ? a.bpm : (b.bpm > 30 ? b.bpm : 120))
        let rateA: Float = tempo.map { clampRate($0.rateA) } ?? 1
        let rateB: Float = tempo.map { clampRate($0.rateB) } ?? 1
        let barSec = 240.0 / Double(max(60, bpm))
        let bars = 4.0
        let blendSec = max(4, bars * barSec)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: blendSec)
        let outCue = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIn = BeatGridSynchronization.incomingCue(profile: b, duration: blendSec)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIn) < abs($1 - rawIn) }) ?? rawIn
        let handoffBar = bars * 0.65
        let bassBar = bars * 0.35
        let events: [FxEvent] = [
            FxEvent(target: .a, kind: .volume, startBar: 0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: min(1.5, bars * 0.4),
                    fromValue: -18, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .bassKill, startBar: 0, endBar: bassBar,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            FxEvent(target: .b, kind: .bassOn, startBar: bassBar, endBar: min(bars, bassBar + 1),
                    fromValue: 1, toValue: 0, curve: .sCurve),
            FxEvent(target: .b, kind: .vocalDucking, startBar: 0, endBar: handoffBar,
                    fromValue: -4, toValue: 0, curve: .sCurve),
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: min(2, bars * 0.45),
                    fromValue: 1100, toValue: 20_000, curve: .exp),
            FxEvent(target: .a, kind: .highPass, startBar: max(0, handoffBar - 0.4), endBar: bars,
                    fromValue: 20, toValue: 4200, curve: .exp),
            FxEvent(target: .a, kind: .echoOut, startBar: max(0, handoffBar), endBar: bars,
                    fromValue: 0, toValue: 42, curve: .sCurve, param: 50)
        ]
        return TransitionPlan(
            type: tempo == nil ? .filterEcho : .beatmatchedShort,
            archetype: .dropSwap,
            aOutStartSec: outCue,
            bInStartSec: incoming,
            bars: bars,
            tempoTargetBPM: tempo == nil ? 0 : bpm,
            rateA: rateA,
            rateB: rateB,
            pitchShiftCentsB: max(-200, min(200, harmonic.pitchShiftCents)),
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0,
            fx: events,
            reason: "DUET · soft · vocal A + vocal B · \(note.isEmpty ? harmonic.description : note)"
        )
    }

    private static func clampRate(_ rate: Float) -> Float {
        guard rate.isFinite, rate > 0 else { return 1 }
        return max(0.84, min(1.16, rate))
    }

    // 1. Архетип Seamless Loop: длинное перетекание (16-32 такта) без среза середины
    private static func planSeamlessLoop(from a: TrackProfile, to b: TrackProfile,
                                         tempo: BeatGridSynchronization.TempoMatch,
                                         settings: MixSettings,
                                         harmonic: HarmonicMatch) -> TransitionPlan {
        var bars = 16.0
        let durationAt16 = BeatGridSynchronization.duration(bars: 16.0, bpm: tempo.targetBPM)
        let availableOutro = max(0, a.durationSec - a.mixOutSec)
        if availableOutro >= durationAt16 * 1.5 && a.durationSec > 180 {
            bars = 24.0
        }

        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: tempo.targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let half = bars / 2.0
        // Phrase loop on A outro (2 or 4 bars) while B blooms — DualDeck seek-loop via executor.
        let loopBars = availableOutro >= durationAt16 * 1.2 ? 4 : 2
        let events = [
            // Мягкий фейд громкостей равной мощности без провала середины
            FxEvent(target: .a, kind: .volume, startBar: half * 0.5, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: half * 1.5,
                    fromValue: -30, toValue: 0, curve: .sCurve),
            // Аккуратный срез самых низких частот (20 -> 800 Гц), вокал и середина не страдают
            FxEvent(target: .a, kind: .highPass, startBar: half, endBar: bars,
                    fromValue: 20, toValue: 800, curve: .exp),
            // Легкое приглушение баса на обоих треках в центре для предотвращения перегрузки низов
            FxEvent(target: .a, kind: .bassKill, startBar: half - 2, endBar: half + 2,
                    fromValue: 0, toValue: 0.25, curve: .sCurve),
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: half,
                    fromValue: 0.25, toValue: 0, curve: .sCurve),
            // Soft tempo-synced delay into LAND — smooth glue, not an echo freeze.
            FxEvent(target: .a, kind: .echoOut, startBar: max(0, bars - 4), endBar: bars,
                    fromValue: 0, toValue: 28, curve: .sCurve, param: 22),
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: min(4, half),
                    fromValue: 2400, toValue: 20_000, curve: .exp),
            FxEvent(target: .b, kind: .rateRamp, startBar: max(0, bars - 2), endBar: bars,
                    fromValue: tempo.rateB, toValue: 1, curve: .sCurve)
        ]

        return TransitionPlan(
            type: .beatmatchedLong,
            archetype: .seamlessLoop,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: tempo.targetBPM, rateA: tempo.rateA, rateB: tempo.rateB,
            pitchShiftCentsB: harmonic.pitchShiftCents,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: loopBars, fx: events,
            reason: "Seamless Loop (\(Int(bars)) тактов · loop \(loopBars) @ \(Int(round(tempo.targetBPM))) BPM, \(harmonic.description))"
        )
    }

    // Space Reverb: musical plate wash on DualDeck (not system Spatial Audio).
    private static func planSpaceReverb(from a: TrackProfile, to b: TrackProfile,
                                        bars: Double,
                                        tempo: BeatGridSynchronization.TempoMatch,
                                        settings: MixSettings,
                                        harmonic: HarmonicMatch) -> TransitionPlan {
        let blendBars = min(12.0, max(8.0, bars))
        let seconds = BeatGridSynchronization.duration(bars: blendBars, bpm: tempo.targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming
        let conflict = oneVocalConflict(a: a, b: b)
        let handoff = blendBars * 0.62
        // AVAudioUnitReverbPreset.mediumHall.rawValue == 3 — DualDeck loads it when wet > 0.
        let hallPreset: Float = 3
        let events: [FxEvent] = [
            FxEvent(target: .a, kind: .volume, startBar: blendBars * 0.25, endBar: blendBars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: handoff,
                    fromValue: -28, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .bassKill, startBar: 0, endBar: blendBars * 0.4,
                    fromValue: 0, toValue: 0.85, curve: .sCurve),
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: blendBars * 0.35,
                    fromValue: 0.7, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .instrumentalize, startBar: 0, endBar: blendBars * 0.3,
                    fromValue: conflict ? 0.55 : 0.2, toValue: conflict ? 1 : 0.65, curve: .sCurve),
            FxEvent(target: .b, kind: .instrumentalize, startBar: 0, endBar: handoff,
                    fromValue: conflict ? 0.85 : 0.2, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .highPass, startBar: handoff - 1, endBar: blendBars,
                    fromValue: 20, toValue: 1400, curve: .exp),
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: min(3, blendBars * 0.4),
                    fromValue: 1400, toValue: 20_000, curve: .exp),
            // Plate wash blooms then clears into dry B LAND.
            FxEvent(target: .a, kind: .reverbWash, startBar: blendBars * 0.2, endBar: blendBars * 0.75,
                    fromValue: 0, toValue: 42, curve: .sCurve, param: hallPreset),
            FxEvent(target: .a, kind: .reverbWash, startBar: blendBars * 0.75, endBar: blendBars,
                    fromValue: 42, toValue: 0, curve: .sCurve, param: hallPreset),
            FxEvent(target: .a, kind: .echoOut, startBar: handoff, endBar: blendBars,
                    fromValue: 0, toValue: 30, curve: .sCurve, param: 24),
            FxEvent(target: .b, kind: .rateRamp, startBar: max(0, blendBars - 1.5), endBar: blendBars,
                    fromValue: tempo.rateB, toValue: 1, curve: .sCurve)
        ]
        return TransitionPlan(
            type: .beatmatchedShort,
            archetype: .spaceReverb,
            aOutStartSec: out, bInStartSec: incoming, bars: blendBars,
            tempoTargetBPM: tempo.targetBPM, rateA: tempo.rateA, rateB: tempo.rateB,
            pitchShiftCentsB: harmonic.pitchShiftCents,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 2, fx: events,
            reason: "Space Reverb (\(Int(blendBars)) тактов · plate wash, \(harmonic.description))"
        )
    }

    // 2. Архетип Drop Swap: сведение в дроп (резонансный свип, срез баса на -40 dB и взрыв на сильную долю)
    private static func planDropSwap(from a: TrackProfile, to b: TrackProfile,
                                     bars: Double,
                                     tempo: BeatGridSynchronization.TempoMatch,
                                     settings: MixSettings,
                                     harmonic: HarmonicMatch) -> TransitionPlan {
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: tempo.targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let conflict = oneVocalConflict(a: a, b: b)
        let handoffBar = bars * 0.55
        let events = [
            FxEvent(target: .a, kind: .volume, startBar: 0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: min(2, bars / 2),
                    fromValue: -40, toValue: 0, curve: .sCurve),
            // Bass Swap: срез уходящего баса, удержание входящего на -40 dB, взрыв на дропе
            FxEvent(target: .a, kind: .bassKill, startBar: 0, endBar: min(2, bars / 2),
                    fromValue: 0, toValue: 1, curve: .sCurve),
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: 0,
                    fromValue: 1, toValue: 1, curve: .linear),
            FxEvent(target: .b, kind: .bassOn, startBar: min(2, bars / 2), endBar: min(bars, min(2, bars / 2) + 1),
                    fromValue: 1, toValue: 0, curve: .sCurve),
            // Lab ONE VOCAL: instrumentalize A (and B until LAND when both leads present).
            FxEvent(target: .a, kind: .instrumentalize, startBar: 0, endBar: min(2, bars * 0.25),
                    fromValue: conflict ? 0.55 : 0.25, toValue: conflict ? 1 : 0.75, curve: .sCurve),
            FxEvent(target: .b, kind: .instrumentalize, startBar: 0, endBar: handoffBar,
                    fromValue: conflict ? 1 : 0.15, toValue: conflict ? 0.15 : 0, curve: .sCurve),
            FxEvent(target: .b, kind: .vocalDucking, startBar: 0, endBar: handoffBar,
                    fromValue: conflict ? -14 : -8, toValue: 0, curve: .sCurve),
            // Soft HPF exit (was 4500 Hz riser — whistly/cheap under stems).
            FxEvent(target: .a, kind: .highPass, startBar: max(0, bars - 3), endBar: bars,
                    fromValue: 20, toValue: 1800, curve: .exp),
            // Low-Pass Reveal
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: min(2, bars / 2),
                    fromValue: 1600, toValue: 20_000, curve: .exp),
            // Light echo tail (was wet 65 / fb 50 — delay wash).
            FxEvent(target: .a, kind: .echoOut, startBar: max(0, bars - 2.5), endBar: bars,
                    fromValue: 0, toValue: 32, curve: .sCurve, param: 24),
            FxEvent(target: .b, kind: .rateRamp, startBar: max(0, bars - 1), endBar: bars,
                    fromValue: tempo.rateB, toValue: 1, curve: .sCurve)
        ]

        let planType: TransitionType = (bars >= 16 && harmonic.isNaturallyCompatible) ? .beatmatchedLong : .beatmatchedShort
        return TransitionPlan(
            type: planType,
            archetype: .dropSwap,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: tempo.targetBPM, rateA: tempo.rateA, rateB: tempo.rateB,
            pitchShiftCentsB: harmonic.pitchShiftCents,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0, fx: events,
            reason: harmonic.isNaturallyCompatible
                ? "Beatmatch + Camelot (\(Int(bars)) тактов, \(harmonic.description))"
                : "Drop Swap (\(Int(bars)) тактов, \(harmonic.description))"
        )
    }

    // 3. Echo Out / Freeze: key clash or far tempo — keep beatmatch when tempos still lock.
    private static func planEchoFreeze(from a: TrackProfile, to b: TrackProfile,
                                       tempo: BeatGridSynchronization.TempoMatch?,
                                       settings: MixSettings,
                                       harmonic: HarmonicMatch) -> TransitionPlan {
        let beatmatched = tempo != nil
        let conflict = oneVocalConflict(a: a, b: b)
        let bpmGap: Float = (a.bpm > 30 && b.bpm > 30) ? abs(a.bpm - b.bpm) / max(a.bpm, 1) : 0.2
        // Per-pair bar count — field 1047 stacked identical ~8-bar echo freezes.
        let bars: Double
        if !beatmatched {
            bars = bpmGap > 0.2 ? 4.0 : 6.0
        } else if !harmonic.isHarmonicallyViable {
            bars = bpmGap > 0.1 ? 6.0 : (conflict ? 8.0 : 10.0)
        } else if conflict {
            bars = 10.0
        } else {
            bars = 8.0
        }
        let targetBPM: Float = tempo?.targetBPM
            ?? (a.bpm > 30 ? a.bpm : (b.bpm > 30 ? b.bpm : 120.0))
        let rateA: Float = tempo.map { max(0.84, min(1.16, $0.rateA)) } ?? 1.0
        let rateB: Float = tempo.map { max(0.84, min(1.16, $0.rateB)) } ?? 1.0
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming
        var events: [FxEvent] = [
            // Dual-layer: A holds into echo while B locks under, then LAND.
            FxEvent(target: .a, kind: .volume, startBar: bars * 0.35, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: bars * 0.55,
                    fromValue: -28, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .bassKill, startBar: 0, endBar: bars * 0.35,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: bars * 0.3,
                    fromValue: 0.85, toValue: 0, curve: .sCurve),
            // Lab ONE VOCAL: instrumentalize both leads until LAND.
            FxEvent(target: .a, kind: .instrumentalize, startBar: 0, endBar: bars * 0.25,
                    fromValue: 0.6, toValue: 1, curve: .sCurve),
            FxEvent(target: .b, kind: .instrumentalize, startBar: 0, endBar: bars * 0.6,
                    fromValue: conflict ? 1 : 0.35, toValue: conflict ? 0.1 : 0, curve: .sCurve),
            FxEvent(target: .b, kind: .vocalDucking, startBar: 0, endBar: bars * 0.6,
                    fromValue: conflict ? -14 : -10, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .echoOut, startBar: bars * 0.55, endBar: bars,
                    fromValue: 0, toValue: 34, curve: .sCurve, param: 26),
            FxEvent(target: .a, kind: .highPass, startBar: bars * 0.55, endBar: bars,
                    fromValue: 20, toValue: 1600, curve: .exp)
        ]
        if beatmatched {
            events.append(
                FxEvent(target: .b, kind: .rateRamp, startBar: max(0, bars - 1.5), endBar: bars,
                        fromValue: rateB, toValue: 1, curve: .sCurve)
            )
        }

        return TransitionPlan(
            type: .filterEcho,
            archetype: .echoFreeze,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: targetBPM, rateA: rateA, rateB: rateB,
            pitchShiftCentsB: max(-200, min(200, harmonic.pitchShiftCents)),
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0, fx: events,
            reason: beatmatched
                ? "Echo Out + beatmatch (\(Int(bars)) тактов @ \(Int(round(targetBPM))) BPM, \(harmonic.description))"
                : "Echo Freeze (\(Int(bars)) тактов, \(Int(round(a.bpm))) → \(Int(round(b.bpm))) BPM, \(harmonic.description))"
        )
    }

    // 4. Архетип Energy Wash: мягкий HPF кроссфейд — всё равно lock BPM when tempos exist.
    private static func planEnergyWash(from a: TrackProfile, to b: TrackProfile,
                                       settings: MixSettings,
                                       harmonic: HarmonicMatch) -> TransitionPlan {
        let bars = 8.0
        let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm)
        let targetBPM: Float = tempo?.targetBPM
            ?? (a.bpm > 30 ? a.bpm : (b.bpm > 30 ? b.bpm : 120.0))
        let rateA: Float = tempo.map { max(0.84, min(1.16, $0.rateA)) } ?? 1.0
        let rateB: Float = tempo.map { max(0.84, min(1.16, $0.rateB)) } ?? 1.0
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        var events: [FxEvent] = [
            FxEvent(target: .a, kind: .volume, startBar: 2.0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: 6.0,
                    fromValue: -40, toValue: 0, curve: .sCurve),
            FxEvent(target: .a, kind: .highPass, startBar: 0, endBar: bars,
                    fromValue: 20, toValue: 2500, curve: .exp),
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: 6.0,
                    fromValue: 1000, toValue: 20000, curve: .exp),
            FxEvent(target: .a, kind: .echoOut, startBar: 3.0, endBar: bars,
                    fromValue: 0, toValue: 50, curve: .sCurve, param: 45)
        ]
        if tempo != nil {
            events.append(
                FxEvent(target: .b, kind: .rateRamp, startBar: max(0, bars - 1.5), endBar: bars,
                        fromValue: rateB, toValue: 1, curve: .sCurve)
            )
        }

        return TransitionPlan(
            type: .filterEcho,
            archetype: .energyWash,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: targetBPM, rateA: rateA, rateB: rateB,
            pitchShiftCentsB: harmonic.pitchShiftCents,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0, fx: events,
            reason: tempo != nil
                ? "Energy Wash + beatmatch (\(Int(round(targetBPM))) BPM, \(harmonic.description))"
                : "Energy Wash (\(harmonic.description))"
        )
    }

    // 5. Архетип Tape Stop: виниловое замедление — B still locks to the shared grid.
    private static func planTapeStop(from a: TrackProfile, to b: TrackProfile,
                                     bars: Double = 4.0,
                                     settings: MixSettings,
                                     harmonic: HarmonicMatch) -> TransitionPlan {
        let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm)
        let targetBPM: Float = tempo?.targetBPM
            ?? (b.bpm > 30 ? b.bpm : (a.bpm > 30 ? a.bpm : 120.0))
        let rateA: Float = tempo.map { max(0.84, min(1.16, $0.rateA)) } ?? 1.0
        let rateB: Float = tempo.map { max(0.84, min(1.16, $0.rateB)) } ?? 1.0
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let events: [FxEvent] = [
            FxEvent(target: .a, kind: .tapeStop, startBar: bars - 0.5, endBar: bars,
                    fromValue: 1.0, toValue: 0.02, curve: .exp),
            FxEvent(target: .a, kind: .lowPass, startBar: bars - 0.5, endBar: bars,
                    fromValue: 20000, toValue: 250, curve: .exp),
            FxEvent(target: .a, kind: .volume, startBar: bars - 0.1, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .linear),
            FxEvent(target: .a, kind: .echoOut, startBar: bars - 0.5, endBar: bars,
                    fromValue: 0, toValue: 30, curve: .sCurve, param: 22),
            FxEvent(target: .b, kind: .volume, startBar: bars - 0.05, endBar: bars,
                    fromValue: -40, toValue: 0, curve: .linear)
        ]

        return TransitionPlan(
            type: .hardCut,
            archetype: .tapeStop,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: targetBPM, rateA: rateA, rateB: rateB,
            pitchShiftCentsB: 0,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0, fx: events,
            reason: tempo != nil
                ? "Tape Stop + beatmatch (\(Int(round(targetBPM))) BPM, \(harmonic.description))"
                : "Tape Stop (\(Int(round(a.bpm))) -> \(Int(round(b.bpm))) BPM, \(harmonic.description))"
        )
    }

    // 6. Архетип Beat Stutter: 1/16 ритмичный ролл перед дропом
    private static func planBeatStutter(from a: TrackProfile, to b: TrackProfile,
                                        bars: Double = 4.0,
                                        tempo: BeatGridSynchronization.TempoMatch,
                                        settings: MixSettings,
                                        harmonic: HarmonicMatch) -> TransitionPlan {
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: tempo.targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let events: [FxEvent] = [
            FxEvent(target: .a, kind: .stutter, startBar: bars - 1.0, endBar: bars,
                    fromValue: 0, toValue: 1, curve: .linear),
            FxEvent(target: .a, kind: .highPass, startBar: bars - 1.0, endBar: bars,
                    fromValue: 20, toValue: 3200, curve: .exp),
            FxEvent(target: .a, kind: .bassKill, startBar: bars - 1.0, endBar: bars,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            FxEvent(target: .a, kind: .volume, startBar: bars - 0.06, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .linear),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: bars - 1.0,
                    fromValue: -40, toValue: -8, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: bars - 0.05, endBar: bars,
                    fromValue: -8, toValue: 0, curve: .linear),
            FxEvent(target: .b, kind: .bassKill, startBar: 0, endBar: bars,
                    fromValue: 1, toValue: 0, curve: .linear)
        ]

        return TransitionPlan(
            type: .beatmatchedShort,
            archetype: .beatStutter,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: tempo.targetBPM, rateA: tempo.rateA, rateB: tempo.rateB,
            pitchShiftCentsB: harmonic.pitchShiftCents,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 1, fx: events,
            reason: "Beat Stutter (\(Int(bars)) тактов · 1/16 gate, \(harmonic.description))"
        )
    }

    /// Lab ONE VOCAL: both leads present around outro/intro → never stack.
    private static func oneVocalConflict(a: TrackProfile, b: TrackProfile) -> Bool {
        let vocalOut = meanTail(a.vocalPresence) ?? meanTail(a.energyCurve) ?? 0.5
        let vocalIn = meanHead(b.vocalPresence) ?? meanHead(b.energyCurve) ?? 0.45
        return vocalOut >= 0.42 && vocalIn >= 0.4
    }

    private static func meanTail(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let start = Int(Double(values.count) * 0.7)
        let slice = values[start...]
        guard !slice.isEmpty else { return nil }
        return slice.reduce(0, +) / Float(slice.count)
    }

    private static func meanHead(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let end = max(1, Int(Double(values.count) * 0.25))
        let slice = values[..<end]
        return slice.reduce(0, +) / Float(slice.count)
    }

    private static func crossfade(_ a: TrackProfile, _ b: TrackProfile,
                                  _ settings: MixSettings, _ reason: String) -> TransitionPlan {
        let seconds = min(16, max(6, settings.crossfadeSeconds))
        let start = min(max(0, a.mixOutSec), max(0, a.durationSec - seconds))
        return TransitionPlan(type: .crossfade, archetype: .energyWash,
                              aOutStartSec: start, bInStartSec: max(0, b.mixInSec), bars: seconds,
                              tempoTargetBPM: 0, rateA: 1, rateB: 1, pitchShiftCentsB: 0,
                              gainOffsetBdB: normalizationGain(profile: b, settings: settings),
                              loopBarsA: 0,
                              fx: [FxEvent(target: .a, kind: .volume, startBar: 0, endBar: seconds, fromValue: 0, toValue: -60, curve: .linear),
                                   FxEvent(target: .b, kind: .volume, startBar: 0, endBar: seconds, fromValue: -60, toValue: 0, curve: .linear)],
                              reason: reason)
    }

    private static func none(a: TrackProfile, reason: String) -> TransitionPlan {
        TransitionPlan(type: .none, archetype: .energyWash,
                       aOutStartSec: a.durationSec, bInStartSec: 0,
                       bars: 0, tempoTargetBPM: 0, rateA: 1, rateB: 1, pitchShiftCentsB: 0,
                       gainOffsetBdB: 0, loopBarsA: 0, fx: [], reason: reason)
    }

    private static func normalizationGain(profile: TrackProfile, settings: MixSettings) -> Float {
        settings.loudnessNormalization ? min(12, max(-12, settings.targetLUFS - profile.integratedLUFS)) : 0
    }
}

public enum BeatGridSynchronization {
    public struct TempoMatch: Sendable, Equatable { public let targetBPM: Float; public let rateA: Float; public let rateB: Float }
    /// Pick a shared grid tempo. Rates are always `target / naturalFileBPM`.
    /// Default ±8% matches `MashupLiveStyle.clampRate` — wider geometric "locks"
    /// (field 1151: 91↔120 → 1.15/0.87) were crushed to 1.08/0.92 and never met.
    /// Prefer A locked so the playing track does not pitch-shift during lead-in.
    public static func tempoMatch(aBPM: Float, bBPM: Float, maximumRateChange: Float = 0.08) -> TempoMatch? {
        guard aBPM.isFinite, bBPM.isFinite, aBPM > 30, bBPM > 30 else { return nil }

        struct Cand {
            let target: Float
            let rateA: Float
            let rateB: Float
            /// Prefer keeping A at 1.0 (solo lead-in stays natural).
            var cost: Float { abs(rateA - 1) * 2 + abs(rateB - 1) }
        }

        let slack = maximumRateChange + 0.005
        var cands: [Cand] = []

        // A locked: only B shifts toward A.
        let directB = aBPM / bBPM
        if abs(directB - 1) <= slack {
            cands.append(Cand(target: aBPM, rateA: 1, rateB: directB))
        }
        // B locked: only A shifts toward B.
        let directA = bBPM / aBPM
        if abs(directA - 1) <= slack {
            cands.append(Cand(target: bBPM, rateA: directA, rateB: 1))
        }

        // Wide gaps (66↔99, 91↔120) return nil; AutoMix uses a safe fade.
        guard let best = cands.min(by: { $0.cost < $1.cost }) else { return nil }
        guard abs(best.rateA - 1) <= slack, abs(best.rateB - 1) <= slack else { return nil }
        return TempoMatch(targetBPM: best.target, rateA: best.rateA, rateB: best.rateB)
    }
    public static func duration(bars: Double, bpm: Float) -> Double { bpm > 0 ? bars * 240 / Double(bpm) : 0 }
    public static func outgoingCue(profile: TrackProfile, duration: Double) -> Double {
        let minCue = max(0, profile.durationSec * 0.75)
        let latest = min(max(minCue, profile.mixOutSec), max(minCue, profile.durationSec - duration))
        if let downbeat = profile.downbeatsSec.last(where: { $0 <= latest && $0 >= minCue }) {
            if let phrase = profile.phraseStartsSec.last(where: { $0 <= latest && $0 >= minCue }) {
                let beat = profile.bpm > 0 ? 60.0 / Double(profile.bpm) : 0.5
                if let matched = profile.downbeatsSec.min(by: { abs($0 - phrase) < abs($1 - phrase) }),
                   abs(matched - phrase) <= beat {
                    return matched
                }
            }
            return downbeat
        }
        return profile.phraseStartsSec.last(where: { $0 <= latest && $0 >= minCue }) ?? latest
    }
    public static func incomingCue(profile: TrackProfile, duration: Double = 0) -> Double {
        // Prefer musical intro (mixIn / first phrase). Drop-alignment only when the
        // resulting cue stays in the intro — otherwise LAND jumps mid-body of B.
        // Field 1151: mixIn≈0 + first downbeat at 0.1 baked cueB=0.1 (silence/cold open).
        let floorIn = max(profile.mixInSec, profile.durationSec > 30 ? 4.0 : 0)
        if duration > 0, let drop = profile.dropsSec.first(where: { $0 >= 8.0 && $0 <= 45.0 }) {
            let halfDuration = duration / 2.0
            if drop >= halfDuration {
                let targetIn = max(floorIn, drop - halfDuration)
                let introCap = max(floorIn + 8, min(18, profile.durationSec * 0.18))
                if targetIn <= introCap {
                    if let matched = profile.downbeatsSec.min(by: { abs($0 - targetIn) < abs($1 - targetIn) }),
                       matched >= floorIn - 0.05 {
                        return matched
                    }
                    return targetIn
                }
            }
        }
        if let firstDownbeat = profile.downbeatsSec.first(where: { $0 >= floorIn }) {
            let fourBars = profile.bpm > 0 ? 16.0 * 60.0 / Double(profile.bpm) : 8.0
            if let firstPhrase = profile.phraseStartsSec.first(where: { $0 >= floorIn }),
               firstPhrase - floorIn <= fourBars {
                let beat = profile.bpm > 0 ? 60.0 / Double(profile.bpm) : 0.5
                if let matched = profile.downbeatsSec.min(by: { abs($0 - firstPhrase) < abs($1 - firstPhrase) }),
                   abs(matched - firstPhrase) <= beat,
                   matched >= floorIn - 0.05 {
                    return matched
                }
            }
            return firstDownbeat
        }
        return profile.phraseStartsSec.first(where: { $0 >= floorIn }) ?? floorIn
    }
    public static func phaseErrorMilliseconds(outgoingBeat: Double, incomingBeat: Double, rateA: Float, rateB: Float) -> Double {
        abs(outgoingBeat / Double(rateA) - incomingBeat / Double(rateB)) * 1_000
    }
}

public struct HarmonicMatch: Sendable, Equatable {
    public let isNaturallyCompatible: Bool
    public let pitchShiftCents: Float
    public let isHarmonicallyViable: Bool
    public let description: String

    public init(isNaturallyCompatible: Bool, pitchShiftCents: Float, isHarmonicallyViable: Bool, description: String) {
        self.isNaturallyCompatible = isNaturallyCompatible
        self.pitchShiftCents = pitchShiftCents
        self.isHarmonicallyViable = isHarmonicallyViable
        self.description = description
    }
}

public enum CamelotCompatibility {
    public static func areCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let a = parse(lhs), let b = parse(rhs) else { return false }
        if a == b || (a.number == b.number && a.letter != b.letter) { return true }
        if a.letter == b.letter { let d = abs(a.number - b.number); return d == 1 || d == 11 }
        return false
    }

    /// - Parameter maxSemitones: pitch compensation ceiling (AutoMix ±2, Duet ±3).
    public static func match(_ keyA: String?, _ keyB: String?, maxSemitones: Int = 2) -> HarmonicMatch {
        guard let rawA = keyA, let rawB = keyB,
              let a = parse(rawA), let b = parse(rawB) else {
            return HarmonicMatch(isNaturallyCompatible: false, pitchShiftCents: 0,
                                 isHarmonicallyViable: true, description: "Тональность не определена")
        }

        // 1. Естественная совместимость по колесу Камелот (тот же ключ, параллельный мажор/минор, смежные ±1)
        if areCompatible(rawA, rawB) {
            let label = (a == b) ? "Точное совпадение ключа (\(rawA))" :
                (a.number == b.number ? "Относительный мажор/минор (\(rawA) ↔ \(rawB))" : "Смежный ключ (\(rawA) → \(rawB))")
            return HarmonicMatch(isNaturallyCompatible: true, pitchShiftCents: 0,
                                 isHarmonicallyViable: true, description: label)
        }

        // 2. Расчет расстояния в полутонах
        let pcA = pitchClass(number: a.number, letter: a.letter)
        let targetPcB = (a.letter == b.letter) ? pcA : (a.letter == "A" ? (pcA + 3) % 12 : (pcA + 9) % 12)
        let pcB = pitchClass(number: b.number, letter: b.letter)

        var semitones = (targetPcB - pcB) % 12
        if semitones > 6 { semitones -= 12 }
        if semitones < -6 { semitones += 12 }

        let cap = max(0, min(6, maxSemitones))
        // Always bias B toward A within the cap — field 1053 left pitchB=0 on
        // 6-semitone clashes so Automix never keyed the incoming stem.
        let applied = max(-cap, min(cap, semitones))
        let cents = Float(applied * 100)
        if abs(semitones) <= cap {
            let sign = cents > 0 ? "+\(Int(cents))" : "\(Int(cents))"
            return HarmonicMatch(
                isNaturallyCompatible: false,
                pitchShiftCents: cents,
                isHarmonicallyViable: true,
                description: "Гармоническая подстройка: \(sign) центов (\(rawA) ↔ \(rawB))"
            )
        }

        let partial = cents == 0 ? "" : " · partial \(cents > 0 ? "+" : "")\(Int(cents))¢"
        return HarmonicMatch(
            isNaturallyCompatible: false,
            pitchShiftCents: cents,
            isHarmonicallyViable: false,
            description: "Тональный конфликт (\(rawA) vs \(rawB), разрыв \(abs(semitones)) полутонов)\(partial)"
        )
    }

    private static func pitchClass(number: Int, letter: Character) -> Int {
        // Таблица Pitch Class (0 = C, 1 = C#, 2 = D ... 11 = B)
        if letter == "A" {
            // Minor: 1A=Abm(8), 2A=Ebm(3), 3A=Bbm(10), 4A=Fm(5), 5A=Cm(0), 6A=Gm(7),
            //        7A=Dm(2), 8A=Am(9), 9A=Em(4), 10A=Bm(11), 11A=F#m(6), 12A=C#m(1)
            let minorMap = [1: 8, 2: 3, 3: 10, 4: 5, 5: 0, 6: 7, 7: 2, 8: 9, 9: 4, 10: 11, 11: 6, 12: 1]
            return minorMap[number] ?? 0
        } else {
            // Major: 1B=B(11), 2B=F#(6), 3B=Db(1), 4B=Ab(8), 5B=Eb(3), 6B=Bb(10),
            //        7B=F(5), 8B=C(0), 9B=G(7), 10B=D(2), 11B=A(9), 12B=E(4)
            let majorMap = [1: 11, 2: 6, 3: 1, 4: 8, 5: 3, 6: 10, 7: 5, 8: 0, 9: 7, 10: 2, 11: 9, 12: 4]
            return majorMap[number] ?? 0
        }
    }

    private static func parse(_ value: String?) -> (number: Int, letter: Character)? {
        guard let value, let letter = value.last, letter == "A" || letter == "B",
              let number = Int(value.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter)
    }
}
