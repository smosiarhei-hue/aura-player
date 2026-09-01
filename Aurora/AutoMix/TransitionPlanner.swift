import Foundation

nonisolated enum TransitionPlanner {
    // Weighted scoring weights (TZ Section 7)
    static let rhythmWeight: Double = 0.25
    static let harmonicWeight: Double = 0.15
    static let energyWeight: Double = 0.20
    static let structureWeight: Double = 0.25
    static let vocalWeight: Double = 0.10
    static let confidenceWeight: Double = 0.05

    static let minStretch: Double = 0.94
    static let maxStretch: Double = 1.06

    // MARK: - Compatibility scores

    nonisolated static func rhythmScore(sourceBPM: Double, targetBPM: Double) -> Double {
        let ratio = max(sourceBPM, targetBPM) / max(1, min(sourceBPM, targetBPM))
        if ratio <= 1.03 { return 1.0 }
        if ratio <= 1.08 { return 0.85 }
        return max(0, 1.0 - (ratio - 1.0) / 0.35)
    }

    nonisolated static func harmonicScore(source: TrackAnalysis, target: TrackAnalysis) -> Double {
        guard let a = source.camelotPosition, let b = target.camelotPosition else { return 0.5 }
        return Double(CamelotWheel.compatibility(a, b))
    }

    // MARK: - Local Fallback Decision Planning (offline DSP decision engine)

    /// Builds a complete executable TransitionPlan without any network access.
    /// Runs when Gemini is unavailable, unconfigured or returned garbage, and
    /// also backs `sanitize(...)` when an AI plan cannot be repaired.
    nonisolated static func planLocalFallback(
        sourceTrackID: UUID,
        sourceAnalysis: TrackAnalysis,
        targetTrackID: UUID,
        targetAnalysis: TrackAnalysis
    ) -> TransitionPlan {
        let sourceDur = max(8.0, sourceAnalysis.duration)
        let targetDur = max(8.0, targetAnalysis.duration)

        let srcBPM = sourceAnalysis.bpm ?? targetAnalysis.bpm ?? 0
        let tgtBPM = targetAnalysis.bpm ?? sourceAnalysis.bpm ?? 0
        let bothTempiKnown = sourceAnalysis.bpm != nil && targetAnalysis.bpm != nil
        let bpmRatio = bothTempiKnown ? (max(srcBPM, tgtBPM) / max(1, min(srcBPM, tgtBPM))) : 2.0

        let energyDiff = abs(sourceAnalysis.energy - targetAnalysis.energy)

        // --- 1. Score components (TZ Section 7) ---
        let rhythm = bothTempiKnown ? rhythmScore(sourceBPM: srcBPM, targetBPM: tgtBPM) : 0.4
        let harmonic = harmonicScore(source: sourceAnalysis, target: targetAnalysis)
        let energyScore = max(0, 1.0 - energyDiff * 1.6)
        let structureScore = (sourceAnalysis.outroStart > 1 && targetAnalysis.introEnd > 1) ? 0.9 : 0.5
        let confidenceScore = min(sourceAnalysis.bpmConfidence, targetAnalysis.bpmConfidence)

        // Vocal collision risk: does the blend window overlap active vocals on both sides?
        let blendProbeStart = sourceDur - min(18, sourceDur * 0.25)
        let sourceVocalAtBlend = sourceAnalysis.vocalActive(at: blendProbeStart) || sourceAnalysis.vocalActive(at: sourceDur - 2)
        let targetVocalAtStart = targetAnalysis.vocalActive(at: 2) || targetAnalysis.vocalActive(at: 8)
        let vocalCollision = sourceVocalAtBlend && targetVocalAtStart
        let vocalScore = vocalCollision ? 0.25 : (sourceVocalAtBlend || targetVocalAtStart ? 0.6 : 1.0)

        let totalScore =
            rhythm * rhythmWeight
            + harmonic * harmonicWeight
            + energyScore * energyWeight
            + structureScore * structureWeight
            + vocalScore * vocalWeight
            + confidenceScore * confidenceWeight

        // --- 2. Strategy selection (TZ Sections 6, 14, 26) ---
        var strategy: TransitionStrategy
        var reason: String
        var sourceRate = 1.0
        var targetRate = 1.0

        let trailingSilence = sourceAnalysis.trailingSilence?.duration ?? 0
        let beatOK = bothTempiKnown
            && sourceAnalysis.bpmConfidence >= 0.65
            && targetAnalysis.bpmConfidence >= 0.65
            && sourceAnalysis.hasSteadyBeat && targetAnalysis.hasSteadyBeat

        // Time stretch: only when both tempi are known, close, and confident.
        if beatOK, bpmRatio > 1.005 {
            let avg = (srcBPM + tgtBPM) / 2
            let s = avg / srcBPM
            let t = avg / tgtBPM
            if s >= minStretch, s <= maxStretch, t >= minStretch, t <= maxStretch {
                sourceRate = s
                targetRate = t
            }
        }
        let canBeatMatch = beatOK && bpmRatio <= 1.08 && sourceRate <= maxStretch && targetRate <= maxStretch

        if trailingSilence > 3.0 {
            strategy = .SILENCE_TRIM
            reason = "Хвостовая тишина \(String(format: "%.1f", trailingSilence)) с — убираем паузу вместо сведения"
        } else if !bothTempiKnown || bpmRatio > 1.28 {
            // Huge or unknown tempo gap: never force a beatmatch (TZ Section 8).
            if targetAnalysis.drops.first(where: { $0 < targetDur * 0.45 }) != nil && targetAnalysis.energy > sourceAnalysis.energy + 0.15 {
                strategy = .DROP_SWITCH
                reason = "Темпы несовместимы: резкий вход на дропе нового трека"
            } else if sourceAnalysis.buildUps.last != nil {
                strategy = .BUILDUP_TO_DROP
                reason = "Разгон уходящего трека завершается дропом входящего"
            } else {
                strategy = .FILTER_TRANSITION
                reason = "Контрастный темп: фильтрация вместо насильного бит-матча"
            }
        } else if vocalCollision {
            // TZ Section 12: never overlap two active vocals with a long crossfade.
            if let vocalEnd = sourceAnalysis.lastVocalEnd, sourceDur - vocalEnd >= 6 {
                strategy = .VOCAL_CUT
                reason = "Вокал уходящего трека заканчивается до перехода — без наложения голосов"
            } else if !targetAnalysis.instrumentalRegions.isEmpty {
                strategy = .INSTRUMENTAL_OVERLAY
                reason = "Входящий трек входит инструментальной частью — вокал не конфликтует"
            } else {
                strategy = .BEAT_MATCH_EQ
                reason = "Короткое сведение с частотным разделением из-за вокала"
            }
        } else if canBeatMatch && energyDiff < 0.20 && harmonic >= 0.85 {
            strategy = .BASS_SWAP
            reason = "Гармоничный DJ Bass-Swap на границе тактов"
        } else if canBeatMatch {
            strategy = .BEAT_MATCH_EQ
            reason = "Бит-матчинг с EQ-разделением низа"
        } else if energyDiff > 0.40 {
            strategy = .ENERGY_BLEND
            reason = "Большая разница энергии: плавный переход с разделением частот"
        } else {
            strategy = .SIMPLE_CROSSFADE
            reason = "Треки совместимы — простое сведение звучит лучше сложного"
        }

        // --- 3. Musical cue time (TZ Sections 10, 23) ---
        let blendDuration = blendLength(
            for: strategy,
            source: sourceAnalysis,
            sourceDur: sourceDur
        )

        var cueTime: TimeInterval
        switch strategy {
        case .VOCAL_CUT:
            cueTime = sourceAnalysis.lastVocalEnd ?? max(0, sourceDur - blendDuration)
        case .SILENCE_TRIM:
            cueTime = max(0, (sourceAnalysis.trailingSilence?.start ?? sourceDur) - 1.0)
        case .BUILDUP_TO_DROP:
            if let buildUp = sourceAnalysis.buildUps.last {
                cueTime = max(buildUp.start, sourceDur - blendDuration - 2)
            } else {
                cueTime = max(0, sourceDur - blendDuration)
            }
        case .DROP_SWITCH:
            cueTime = max(0, sourceDur - min(blendDuration, 4))
        default:
            // Prefer the detected outro; keep at least 60 % of the blend inside.
            let outroCue = sourceAnalysis.outroStart > 1 ? sourceAnalysis.outroStart : sourceDur - blendDuration
            cueTime = min(outroCue, sourceDur - blendDuration * 0.6)
        }

        // Snap the cue to the nearest downbeat so the switch lands on the grid.
        if strategy != .SILENCE_TRIM, let snapped = sourceAnalysis.nearestDownbeat(to: cueTime) {
            cueTime = snapped
        }
        // The blend must END with the track: the cue may never sit further from
        // the end than the blend length (+ a 2 s safety). Otherwise the source
        // would go silent tens of seconds before its file actually ends.
        cueTime = max(cueTime, sourceDur - blendDuration - 2)
        cueTime = min(max(0, cueTime), max(0, sourceDur - 1.5))

        // --- 4. Action envelopes (TZ Sections 11, 15, 16) ---
        let actions = actionEnvelopes(
            strategy: strategy,
            duration: blendDuration
        )

        let fallbackStrategy: TransitionStrategy
        switch strategy {
        case .BASS_SWAP, .BEAT_MATCH, .BEAT_MATCH_EQ: fallbackStrategy = .SIMPLE_CROSSFADE
        case .BUILDUP_TO_DROP, .DROP_SWITCH: fallbackStrategy = .FILTER_TRANSITION
        case .SILENCE_TRIM: fallbackStrategy = .HARD_CUT
        default: fallbackStrategy = .SIMPLE_CROSSFADE
        }

        return TransitionPlan(
            decision: TransitionDecisionInfo(
                transitionType: strategy.rawValue,
                confidence: min(1, max(0.2, totalScore)),
                reason: reason
            ),
            sourceTrack: TransitionSourceTrackInfo(
                transitionStart: cueTime,
                transitionEnd: min(sourceDur, cueTime + blendDuration)
            ),
            targetTrack: TransitionTargetTrackInfo(
                startPosition: 0
            ),
            tempo: TransitionTempoInfo(
                targetBPM: tgtBPM > 0 ? tgtBPM : (srcBPM > 0 ? srcBPM : 120),
                sourcePlaybackRate: sourceRate,
                targetPlaybackRate: targetRate
            ),
            actions: actions,
            fallback: TransitionFallbackInfo(type: fallbackStrategy.rawValue)
        )
    }

    /// Adaptive transition duration (TZ Section 24): strategy-driven, then
    /// quantized to whole bars of the outgoing tempo.
    nonisolated static func blendLength(
        for strategy: TransitionStrategy,
        source: TrackAnalysis,
        sourceDur: TimeInterval
    ) -> TimeInterval {
        var base: TimeInterval
        switch strategy {
        case .SILENCE_TRIM: base = 1.5
        case .HARD_CUT, .DROP_SWITCH: base = 3
        case .VOCAL_CUT: base = 8
        case .FILTER_TRANSITION: base = 12
        case .BUILDUP_TO_DROP: base = 10
        case .ENERGY_BLEND: base = 14
        case .BEAT_MATCH_EQ: base = 16
        case .BASS_SWAP: base = 18
        default: base = 9
        }

        // Keep the blend inside the real remaining window.
        let usable = max(4, sourceDur * 0.4)
        base = min(base, usable)

        // Quantize to whole bars at the source tempo for musical alignment.
        if let bar = source.barDuration, bar > 0.4 {
            let bars = max(1, (base / bar).rounded())
            base = bars * bar
        }
        return min(32, max(2, base))
    }

    // MARK: - Action envelopes

    nonisolated static func actionEnvelopes(
        strategy: TransitionStrategy,
        duration: Double
    ) -> [TransitionAction] {
        var actions: [TransitionAction] = []
        let half = duration / 2

        switch strategy {
        case .BASS_SWAP, .BEAT_MATCH_EQ, .BEAT_MATCH:
            // Source keeps full level, loses the low end; target enters mid/high
            // only and receives the bass on a musical boundary (TZ Section 11).
            // Both lanes ride real ramps - no instant jumps, no dead air.
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: 0))
            actions.append(TransitionAction(time: 0, target: "source", parameter: "lowEQ", value: 0.95, duration: half))
            actions.append(TransitionAction(time: half, target: "source", parameter: "lowEQ", value: 0.05, duration: half))
            actions.append(TransitionAction(time: duration * 0.5, target: "source", parameter: "volume", value: 1.0, duration: duration * 0.4))
            actions.append(TransitionAction(time: duration * 0.9, target: "source", parameter: "volume", value: 0.0, duration: duration * 0.1))

            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 0.0, duration: duration * 0.55))
            actions.append(TransitionAction(time: duration * 0.55, target: "target", parameter: "volume", value: 0.7, duration: duration * 0.45))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "lowEQ", value: 0.0, duration: half * 0.6))
            actions.append(TransitionAction(time: half * 0.6, target: "target", parameter: "lowEQ", value: 1.0, duration: half * 0.4))

        case .FILTER_TRANSITION:
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: half))
            actions.append(TransitionAction(time: half, target: "source", parameter: "volume", value: 0.35, duration: half))
            actions.append(TransitionAction(time: 0, target: "source", parameter: "filter", value: 1.0, duration: 0))
            actions.append(TransitionAction(time: half, target: "source", parameter: "filter", value: 0.1, duration: half))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 0.1, duration: 0))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 1.0, duration: half * 1.2))

        case .DROP_SWITCH, .HARD_CUT:
            // Deliberate hard style: source rides at full level until the very
            // last beat, target enters at once on the switch.
            actions.append(TransitionAction(time: duration * 0.8, target: "source", parameter: "volume", value: 1.0, duration: duration * 0.15))
            actions.append(TransitionAction(time: duration * 0.95, target: "source", parameter: "volume", value: 0.0, duration: duration * 0.05))
            actions.append(TransitionAction(time: duration * 0.95, target: "target", parameter: "volume", value: 1.0, duration: 0))

        case .VOCAL_CUT:
            // Outgoing dips under the target's entrance, target rises cleanly;
            // source dies out only at the very end of the window.
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: duration * 0.55))
            actions.append(TransitionAction(time: duration * 0.55, target: "source", parameter: "volume", value: 0.45, duration: duration * 0.3))
            actions.append(TransitionAction(time: duration * 0.85, target: "source", parameter: "volume", value: 0.0, duration: duration * 0.15))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 0.0, duration: 0))
            actions.append(TransitionAction(time: duration * 0.45, target: "target", parameter: "volume", value: 0.75, duration: duration * 0.45))

        default:
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: duration * 0.85))
            actions.append(TransitionAction(time: duration * 0.85, target: "source", parameter: "volume", value: 0.0, duration: duration * 0.15))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 0.0, duration: duration))
            actions.append(TransitionAction(time: duration, target: "target", parameter: "volume", value: 1.0, duration: 0))
        }

        return actions
    }

    // MARK: - AI plan sanitization

    /// Validates a Gemini plan against measured reality and repairs the common
    /// failure modes: invented tempi, out-of-range stretch, cues outside the
    /// track, vocal collisions and missing action envelopes.
    nonisolated static func sanitize(
        _ plan: TransitionPlan,
        sourceAnalysis: TrackAnalysis,
        targetAnalysis: TrackAnalysis
    ) -> TransitionPlan {
        let sourceDur = max(8, sourceAnalysis.duration)

        var cue = plan.sourceTrack.transitionStart
        guard cue.isFinite else {
            return planLocalFallback(
                sourceTrackID: UUID(),
                sourceAnalysis: sourceAnalysis,
                targetTrackID: UUID(),
                targetAnalysis: targetAnalysis
            )
        }
        cue = min(max(0, cue), max(0, sourceDur - 1.5))
        var end = min(plan.sourceTrack.transitionEnd.isFinite ? plan.sourceTrack.transitionEnd : sourceDur, sourceDur)
        if end - cue < 2 { end = min(sourceDur, cue + 4) }
        // The blend must end WITH the track: an early cue would mute the
        // source long before its file ends. Keep at most a 2 s safety gap.
        if sourceDur - end > 2 {
            let blendLength = end - cue
            end = sourceDur
            cue = min(cue, max(0, sourceDur - blendLength - 2))
        }

        // 2. Tempo: clamp rates to the musical stretch window; drop invented rates.
        func clampRate(_ r: Double) -> Double {
            guard r.isFinite, r > 0 else { return 1.0 }
            if r < 0.85 || r > 1.15 { return 1.0 }
            return min(maxStretch, max(minStretch, r))
        }
        var sRate = clampRate(plan.tempo.sourcePlaybackRate)
        let tRate = clampRate(plan.tempo.targetPlaybackRate)
        if let sBPM = sourceAnalysis.bpm {
            let implied = sRate * sBPM
            if implied < 40 || implied > 220 { sRate = 1.0 }
        }

        // 3. Vocal collision check: if the blend window overlaps active vocals
        // on both sides and the plan is a long blend, shorten and separate.
        let blendProbe = cue + (end - cue) * 0.5
        let sourceVocal = sourceAnalysis.vocalActive(at: blendProbe)
        let targetVocal = targetAnalysis.vocalActive(at: plan.targetTrack.startPosition + (end - cue) * 0.5)
        var strategy = plan.strategy
        var reason = plan.decision.reason
        var confidence = plan.decision.confidence
        if sourceVocal && targetVocal, end - cue > 8 {
            strategy = .BEAT_MATCH_EQ
            confidence = max(0.3, confidence * 0.8)
            reason = "AI-план исправлен: вокальный конфликт — укорочено с EQ-разделением"
        }

        // 4. Actions: keep only finite ones targeting source/target; if the AI
        // returned none usable, generate the local envelopes.
        var actions = plan.actions.filter {
            $0.time.isFinite && $0.value.isFinite && ($0.target == "source" || $0.target == "target")
        }
        if actions.isEmpty {
            actions = actionEnvelopes(strategy: strategy, duration: end - cue)
        }

        let targetBPM = plan.tempo.targetBPM.isFinite && plan.tempo.targetBPM > 40 && plan.tempo.targetBPM < 220
            ? plan.tempo.targetBPM
            : (targetAnalysis.bpm ?? sourceAnalysis.bpm ?? 120)

        return TransitionPlan(
            decision: TransitionDecisionInfo(
                transitionType: strategy.rawValue,
                confidence: min(1, max(0.05, confidence.isFinite ? confidence : 0.5)),
                reason: reason
            ),
            sourceTrack: TransitionSourceTrackInfo(transitionStart: cue, transitionEnd: end),
            targetTrack: TransitionTargetTrackInfo(startPosition: max(0, plan.targetTrack.startPosition.isFinite ? plan.targetTrack.startPosition : 0)),
            tempo: TransitionTempoInfo(targetBPM: targetBPM, sourcePlaybackRate: sRate, targetPlaybackRate: tRate),
            actions: actions,
            fallback: TransitionFallbackInfo(type: plan.fallback.type.isEmpty ? TransitionStrategy.SIMPLE_CROSSFADE.rawValue : plan.fallback.type)
        )
    }
}
