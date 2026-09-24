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

        guard a.mixable, b.mixable else {
            return crossfade(a, b, settings, "Fallback: трек не предназначен для сведения")
        }

        let harmonic = CamelotCompatibility.match(a.camelotKey, b.camelotKey)
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
            if bpmDiffPct > 0.15 || !harmonic.isHarmonicallyViable {
                return planEchoFreeze(from: a, to: b, tempo: nil, settings: settings, harmonic: harmonic)
            }
            return crossfade(a, b, settings, "Fallback: темпы нельзя безопасно совместить")
        }

        // Проверка фазового расхождения сетки
        let testDuration = BeatGridSynchronization.duration(bars: ladderBars, bpm: tempo.targetBPM)
        let testOut = BeatGridSynchronization.outgoingCue(profile: a, duration: testDuration)
        let testIn = BeatGridSynchronization.incomingCue(profile: b)
        let phaseA = a.downbeatsSec.min(by: { abs($0 - testOut) < abs($1 - testOut) }).map { abs(testOut - $0) } ?? 0
        let phaseB = b.downbeatsSec.min(by: { abs($0 - testIn) < abs($1 - testIn) }).map { abs(testIn - $0) } ?? 0
        let phaseError = BeatGridSynchronization.phaseErrorMilliseconds(outgoingBeat: phaseA, incomingBeat: phaseB, rateA: tempo.rateA, rateB: tempo.rateB)
        if phaseError > 120 {
            return crossfade(a, b, settings, "Fallback: фазовое расхождение > 120ms")
        }

        let availableOutro = max(0, a.durationSec - a.mixOutSec)

        // Выбор архетипа по матрице переходов (только чистые музыкальные переходы)
        let archetype: MixTransitionArchetype
        if bpmDiffPct > 0.08 || !harmonic.isHarmonicallyViable {
            archetype = (a.confidence.bpm >= 0.7 && b.confidence.bpm >= 0.7) ? .echoFreeze : .energyWash
        } else if ladderBars >= 16.0 && availableOutro >= 36 && bpmDiffPct <= 0.01 && harmonic.isNaturallyCompatible && a.confidence.bpm >= 0.80 {
            archetype = .seamlessLoop
        } else {
            archetype = .dropSwap
        }

        switch archetype {
        case .seamlessLoop:
            return planSeamlessLoop(from: a, to: b, tempo: tempo, settings: settings, harmonic: harmonic)
        case .dropSwap, .tapeStop, .beatStutter:
            return planDropSwap(from: a, to: b, bars: ladderBars, tempo: tempo, settings: settings, harmonic: harmonic)
        case .echoFreeze:
            return planEchoFreeze(from: a, to: b, tempo: tempo, settings: settings, harmonic: harmonic)
        case .spaceReverb:
            return planSpaceReverb(from: a, to: b, bars: 8.0, settings: settings, harmonic: harmonic)
        case .energyWash:
            return planEnergyWash(from: a, to: b, settings: settings, harmonic: harmonic)
        }
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
            loopBarsA: 0, fx: events,
            reason: "Seamless Loop (\(Int(bars)) тактов @ \(Int(round(tempo.targetBPM))) BPM, \(harmonic.description))"
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
            // High-Pass Resonant Riser (20 -> 4500 Гц с подъемом Q)
            FxEvent(target: .a, kind: .highPass, startBar: 0, endBar: bars,
                    fromValue: 20, toValue: 4500, curve: .exp),
            // Low-Pass Reveal (1200 -> 20000 Гц)
            FxEvent(target: .b, kind: .lowPass, startBar: 0, endBar: min(2, bars / 2),
                    fromValue: 1200, toValue: 20000, curve: .exp),
            // Echo Out wash на хвосте (хвост продлится в Delay Spillover на 2.8с)
            FxEvent(target: .a, kind: .echoOut, startBar: max(0, bars - 4), endBar: bars,
                    fromValue: 0, toValue: 65, curve: .sCurve, param: 50),
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

    // 3. Архетип Echo Freeze: удар эха при резком скачке темпа (>15%) или несовместимых ключах
    private static func planEchoFreeze(from a: TrackProfile, to b: TrackProfile,
                                       tempo: BeatGridSynchronization.TempoMatch?,
                                       settings: MixSettings,
                                       harmonic: HarmonicMatch) -> TransitionPlan {
        let bars = 6.0
        let targetBPM: Float = b.bpm > 30 ? b.bpm : (a.bpm > 30 ? a.bpm : 120.0)
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let events: [FxEvent] = [
            // Трек A играет до bars - 1.0, затем громкость отсекается в 0
            FxEvent(target: .a, kind: .volume, startBar: bars - 1.0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .linear),
            // Бас трека A глушится в момент захода в эхо
            FxEvent(target: .a, kind: .bassKill, startBar: bars - 1.5, endBar: bars - 0.5,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            // Сильный Echo Out (Wet 70%, Feedback 60%), хвост которого растворится поверх трека B
            FxEvent(target: .a, kind: .echoOut, startBar: bars - 1.5, endBar: bars,
                    fromValue: 0, toValue: 70, curve: .sCurve, param: 60),
            // Трек B входит на сильную долю (bars) на полной громкости
            FxEvent(target: .b, kind: .volume, startBar: bars - 0.25, endBar: bars,
                    fromValue: -40, toValue: 0, curve: .linear)
        ]

        return TransitionPlan(
            type: .filterEcho,
            archetype: .echoFreeze,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: targetBPM, rateA: 1.0, rateB: 1.0,
            pitchShiftCentsB: 0, // Без питч-шифта, трек B стартует в естественной тональности
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0, fx: events,
            reason: "Echo Freeze (\(Int(round(a.bpm))) -> \(Int(round(b.bpm))) BPM, \(harmonic.description))"
        )
    }

    // 4. Архетип Energy Wash: мягкий HPF кроссфейд при отсутствии ровной сетки (поп/рок)
    private static func planEnergyWash(from a: TrackProfile, to b: TrackProfile,
                                       settings: MixSettings,
                                       harmonic: HarmonicMatch) -> TransitionPlan {
        let bars = 8.0
        let targetBPM: Float = a.bpm > 30 ? a.bpm : (b.bpm > 30 ? b.bpm : 120.0)
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let events: [FxEvent] = [
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

        return TransitionPlan(
            type: .filterEcho,
            archetype: .energyWash,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: targetBPM, rateA: 1.0, rateB: 1.0,
            pitchShiftCentsB: harmonic.pitchShiftCents,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0, fx: events,
            reason: "Energy Wash (\(harmonic.description))"
        )
    }

    // 5. Архетип Tape Stop: виниловое замедление (колесо диджея) перед сильной долей
    private static func planTapeStop(from a: TrackProfile, to b: TrackProfile,
                                     bars: Double = 4.0,
                                     settings: MixSettings,
                                     harmonic: HarmonicMatch) -> TransitionPlan {
        let targetBPM: Float = b.bpm > 30 ? b.bpm : (a.bpm > 30 ? a.bpm : 120.0)
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
                    fromValue: 0, toValue: 65, curve: .sCurve, param: 55),
            FxEvent(target: .b, kind: .volume, startBar: bars - 0.05, endBar: bars,
                    fromValue: -40, toValue: 0, curve: .linear)
        ]

        return TransitionPlan(
            type: .hardCut,
            archetype: .tapeStop,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: targetBPM, rateA: 1.0, rateB: 1.0,
            pitchShiftCentsB: 0,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0, fx: events,
            reason: "Tape Stop (\(Int(round(a.bpm))) -> \(Int(round(b.bpm))) BPM, \(harmonic.description))"
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
            loopBarsA: 0, fx: events,
            reason: "Beat Stutter (\(Int(bars)) тактов, \(harmonic.description))"
        )
    }

    // 7. Архетип Space Reverb: растворение уходящего вокала в реверберации
    private static func planSpaceReverb(from a: TrackProfile, to b: TrackProfile,
                                        bars: Double = 8.0,
                                        settings: MixSettings,
                                        harmonic: HarmonicMatch) -> TransitionPlan {
        let targetBPM: Float = b.bpm > 30 ? b.bpm : (a.bpm > 30 ? a.bpm : 120.0)
        let seconds = BeatGridSynchronization.duration(bars: bars, bpm: targetBPM)
        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: seconds)
        let out = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let rawIncoming = BeatGridSynchronization.incomingCue(profile: b, duration: seconds)
        let incoming = b.downbeatsSec.min(by: { abs($0 - rawIncoming) < abs($1 - rawIncoming) }) ?? rawIncoming

        let events: [FxEvent] = [
            FxEvent(target: .a, kind: .volume, startBar: bars - 2.0, endBar: bars,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .a, kind: .reverbWash, startBar: bars - 2.0, endBar: bars,
                    fromValue: 0, toValue: 90, curve: .sCurve),
            FxEvent(target: .a, kind: .highPass, startBar: bars - 2.0, endBar: bars,
                    fromValue: 20, toValue: 600, curve: .exp),
            FxEvent(target: .a, kind: .bassKill, startBar: bars - 2.0, endBar: bars,
                    fromValue: 0, toValue: 1, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: bars - 0.05, endBar: bars,
                    fromValue: -40, toValue: 0, curve: .linear)
        ]

        return TransitionPlan(
            type: .filterEcho,
            archetype: .spaceReverb,
            aOutStartSec: out, bInStartSec: incoming, bars: bars,
            tempoTargetBPM: targetBPM, rateA: 1.0, rateB: 1.0,
            pitchShiftCentsB: 0,
            gainOffsetBdB: normalizationGain(profile: b, settings: settings),
            loopBarsA: 0, fx: events,
            reason: "Space Reverb (\(harmonic.description))"
        )
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
        // If Track B has an early drop, align it so the drop hits exactly on the transition handoff (midpoint)
        if duration > 0, let drop = profile.dropsSec.first(where: { $0 >= 8.0 && $0 <= 45.0 }) {
            let halfDuration = duration / 2.0
            if drop >= halfDuration {
                let targetIn = drop - halfDuration
                if let matched = profile.downbeatsSec.min(by: { abs($0 - targetIn) < abs($1 - targetIn) }) {
                    return matched
                }
            }
        }
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

    public static func match(_ keyA: String?, _ keyB: String?) -> HarmonicMatch {
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

        // Если разница в пределах ±2 полутонов — компенсируем питч-шифтом (до ±200 центов)
        if abs(semitones) <= 2 {
            let cents = Float(semitones * 100)
            let sign = cents > 0 ? "+\(Int(cents))" : "\(Int(cents))"
            return HarmonicMatch(
                isNaturallyCompatible: false,
                pitchShiftCents: cents,
                isHarmonicallyViable: true,
                description: "Гармоническая подстройка: \(sign) центов (\(rawA) ↔ \(rawB))"
            )
        }

        // Несовместимый ключ (> 2 полутонов) — гармоническое наложение запрещено
        return HarmonicMatch(
            isNaturallyCompatible: false,
            pitchShiftCents: 0,
            isHarmonicallyViable: false,
            description: "Тональный конфликт (\(rawA) vs \(rawB), разрыв \(abs(semitones)) полутонов)"
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
