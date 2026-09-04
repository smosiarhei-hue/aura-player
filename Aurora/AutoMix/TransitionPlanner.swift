// Path: Aurora/AutoMix/TransitionPlanner.swift

import Foundation

nonisolated enum TransitionPlanner {
    static let minStretch = 0.94
    static let maxStretch = 1.06

    nonisolated static func normalizedBPM(_ bpm: Double?) -> Double? {
        guard var value = bpm, value.isFinite, value >= 45, value <= 220 else { return nil }
        while value < 85, value * 2 <= 175 { value *= 2 }
        while value > 175, value / 2 >= 85 { value /= 2 }
        return value
    }

    nonisolated static func rhythmScore(sourceBPM: Double, targetBPM: Double) -> Double {
        guard let source = normalizedBPM(sourceBPM), let target = normalizedBPM(targetBPM) else { return 0 }
        let ratio = max(source, target) / max(1, min(source, target))
        if ratio <= 1.03 { return 1 }
        if ratio <= 1.08 { return 0.9 }
        if ratio <= 1.13 { return 0.72 }
        return max(0, 1 - (ratio - 1) / 0.30)
    }

    nonisolated static func harmonicScore(source: TrackAnalysis, target: TrackAnalysis) -> Double {
        guard let sourcePosition = source.camelotPosition,
              let targetPosition = target.camelotPosition else { return 0.5 }
        return Double(CamelotWheel.compatibility(sourcePosition, targetPosition))
    }

    nonisolated static func bestAutoMixCandidate(
        current: TrackAnalysis,
        candidates: [(track: Track, analysis: TrackAnalysis)]
    ) -> Track? {
        candidates
            .map { candidate in
                let rhythm: Double
                if let sourceBPM = current.bpm, let targetBPM = candidate.analysis.bpm {
                    rhythm = rhythmScore(sourceBPM: sourceBPM, targetBPM: targetBPM)
                } else {
                    rhythm = 0.35
                }
                let harmonic = harmonicScore(source: current, target: candidate.analysis)
                let vocalSafety = vocalCollision(source: current, target: candidate.analysis) ? 0.25 : 1
                let energy = max(0, 1 - abs(current.energy - candidate.analysis.energy) * 1.5)
                return (candidate.track, rhythm * 0.38 + harmonic * 0.34 + vocalSafety * 0.18 + energy * 0.10)
            }
            .filter { $0.1 >= 0.58 }
            .max { $0.1 < $1.1 }?.0
    }

    nonisolated static func planLocalFallback(
        sourceTrackID: UUID,
        sourceAnalysis: TrackAnalysis,
        targetTrackID: UUID,
        targetAnalysis: TrackAnalysis
    ) -> TransitionPlan {
        let sourceDuration = max(8, sourceAnalysis.duration)
        let seed = pairSeed(sourceTrackID: sourceTrackID, targetTrackID: targetTrackID, salt: 17)
        let rhythm = tempoMatch(source: sourceAnalysis, target: targetAnalysis)
        let harmonic = harmonicScore(source: sourceAnalysis, target: targetAnalysis)
        let collision = vocalCollision(source: sourceAnalysis, target: targetAnalysis)
        let energyDifference = abs(sourceAnalysis.energy - targetAnalysis.energy)
        let strategy = chooseStrategy(
            source: sourceAnalysis,
            target: targetAnalysis,
            rhythm: rhythm,
            harmonic: harmonic,
            vocalCollision: collision,
            energyDifference: energyDifference,
            seed: seed
        )
        let duration = blendLength(for: strategy, source: sourceAnalysis, sourceDur: sourceDuration)
        let cue = musicalCueTime(strategy: strategy, source: sourceAnalysis, duration: duration)
        let targetStart = phaseAlignedStart(
            cueTime: cue,
            blendDuration: duration,
            sourceRate: rhythm.sourceRate,
            targetRate: rhythm.targetRate,
            source: sourceAnalysis,
            target: targetAnalysis
        )
        let reverb = chooseReverbPreset(
            source: sourceAnalysis,
            target: targetAnalysis,
            seed: pairSeed(sourceTrackID: sourceTrackID, targetTrackID: targetTrackID, salt: 29)
        )
        let confidence = min(1, max(0.25, rhythm.score * 0.42 + harmonic * 0.28 + (1 - energyDifference) * 0.18 + (collision ? 0.04 : 0.12)))

        return TransitionPlan(
            decision: TransitionDecisionInfo(
                transitionType: strategy.rawValue,
                confidence: confidence,
                reason: reason(for: strategy)
            ),
            sourceTrack: TransitionSourceTrackInfo(
                transitionStart: cue,
                transitionEnd: min(sourceDuration, cue + duration)
            ),
            targetTrack: TransitionTargetTrackInfo(startPosition: targetStart),
            tempo: TransitionTempoInfo(
                targetBPM: normalizedBPM(targetAnalysis.bpm) ?? normalizedBPM(sourceAnalysis.bpm) ?? 120,
                sourcePlaybackRate: rhythm.sourceRate,
                targetPlaybackRate: rhythm.targetRate
            ),
            actions: actionEnvelopes(strategy: strategy, duration: duration),
            fallback: TransitionFallbackInfo(type: TransitionStrategy.ENERGY_BLEND.rawValue),
            effects: TransitionEffects(reverbPreset: reverb)
        )
    }

    nonisolated static func chooseReverbPreset(
        source: TrackAnalysis,
        target: TrackAnalysis,
        seed: UInt64
    ) -> String {
        let averageEnergy = (source.energy + target.energy) / 2
        let averageBPM = [normalizedBPM(source.bpm), normalizedBPM(target.bpm)].compactMap { $0 }
        let tempo = averageBPM.isEmpty ? 120 : averageBPM.reduce(0, +) / Double(averageBPM.count)
        let pool: [String]
        if tempo >= 118 || averageEnergy >= 0.62 {
            pool = ["plate", "smallRoom", "mediumRoom"]
        } else if source.vocalRegions.count + target.vocalRegions.count >= 4 {
            pool = ["mediumChamber", "mediumHall", "largeChamber"]
        } else {
            pool = ["mediumRoom", "mediumHall", "largeRoom"]
        }
        return pool[Int(seed % UInt64(pool.count))]
    }

    nonisolated static func pairSeed(
        sourceTrackID: UUID,
        targetTrackID: UUID,
        salt: Int
    ) -> UInt64 {
        let material = sourceTrackID.uuidString + "|" + targetTrackID.uuidString + "|" + String(salt)
        return material.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    nonisolated private static func chooseStrategy(
        source: TrackAnalysis,
        target: TrackAnalysis,
        rhythm: TempoMatch,
        harmonic: Double,
        vocalCollision: Bool,
        energyDifference: Double,
        seed: UInt64
    ) -> TransitionStrategy {
        if (source.trailingSilence?.duration ?? 0) > 2.5 { return .SILENCE_TRIM }
        if vocalCollision {
            return target.instrumentalRegions.isEmpty ? .VOCAL_CUT : .INSTRUMENTAL_OVERLAY
        }
        if rhythm.canSynchronize, harmonic >= 0.75 {
            return seed.isMultiple(of: 3) ? .BEAT_MATCH_EQ : .BASS_SWAP
        }
        if rhythm.canSynchronize {
            return seed.isMultiple(of: 2) ? .FILTER_TRANSITION : .BEAT_MATCH_EQ
        }
        if energyDifference >= 0.32 { return .ENERGY_BLEND }
        return seed.isMultiple(of: 2) ? .ECHO_OUT : .ENERGY_BLEND
    }

    nonisolated private static func vocalCollision(source: TrackAnalysis, target: TrackAnalysis) -> Bool {
        let sourceProbe = max(0, source.duration - 14)
        return source.vocalActive(at: sourceProbe) && (target.vocalActive(at: 3) || target.vocalActive(at: 8))
    }

    nonisolated private static func reason(for strategy: TransitionStrategy) -> String {
        switch strategy {
        case .BASS_SWAP: return "Фразовое DJ-сведение с синхронизацией темпа и передачей баса"
        case .BEAT_MATCH_EQ: return "Сведение по сетке ударов с частотным разделением"
        case .FILTER_TRANSITION: return "Фильтр-аут уходящего трека и ранний вход следующего"
        case .VOCAL_CUT: return "Короткий переход без наложения двух вокальных партий"
        case .INSTRUMENTAL_OVERLAY: return "Вход через инструментальную фразу без конфликта вокала"
        case .ECHO_OUT: return "Выраженный реверб-хвост с входом следующего трека"
        case .SILENCE_TRIM: return "Хвостовая тишина удалена перед музыкальным переходом"
        default: return "Фразовый энергетический AutoMix с ранним наложением треков"
        }
    }
}
