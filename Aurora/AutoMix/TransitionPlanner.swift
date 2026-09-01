import Foundation

nonisolated enum AutoMixMode: String, Sendable {
    case automix
    case crossfade
    case gapless
    case off
}

nonisolated enum BlendCurve: String, Sendable {
    case bassSwap
    case dissolve
    case cut
}

nonisolated enum TransitionScenario: Sendable, Equatable {
    case fullBlend(bars: Int)
    case crossfade
    case gapRemoval
}

nonisolated struct TransitionDecision: Sendable {
    var scenario: TransitionScenario
    var cueTime: TimeInterval
    var duration: TimeInterval
    var incomingStart: TimeInterval
    var tempoRate: Float
    var curve: BlendCurve
    var score: Float
    var reason: String
    var outgoingLoopStart: TimeInterval? = nil
    var outgoingLoopDuration: TimeInterval = 0

    var isBeatMatched: Bool {
        if case .fullBlend = scenario { return true }
        return false
    }

    var usesBeatLoop: Bool {
        outgoingLoopStart != nil && outgoingLoopDuration > 0.1
    }

    var bars: Int {
        if case .fullBlend(let value) = scenario { return value }
        return 0
    }
}

nonisolated struct TransitionContext: Sendable {
    var outgoingDuration: TimeInterval
    var outgoing: TrackAnalysis?
    var incoming: TrackAnalysis?
    var mode: AutoMixMode
    var crossfadeDuration: TimeInterval
    var maxDuration: TimeInterval
    var sameGenre: Bool?

    init(
        outgoingDuration: TimeInterval,
        outgoing: TrackAnalysis?,
        incoming: TrackAnalysis?,
        mode: AutoMixMode,
        crossfadeDuration: TimeInterval = 4,
        maxDuration: TimeInterval = 18,
        sameGenre: Bool? = nil
    ) {
        self.outgoingDuration = outgoingDuration
        self.outgoing = outgoing
        self.incoming = incoming
        self.mode = mode
        self.crossfadeDuration = crossfadeDuration
        self.maxDuration = maxDuration
        self.sameGenre = sameGenre
    }
}

nonisolated enum TransitionPlanner {
    // Weighted scoring weights (Section 7)
    static let rhythmWeight: Double = 0.25
    static let harmonicWeight: Double = 0.15
    static let energyWeight: Double = 0.20
    static let structureWeight: Double = 0.25
    static let vocalWeight: Double = 0.10
    static let confidenceWeight: Double = 0.05

    // MARK: - Legacy context planning bridge
    nonisolated static func plan(_ context: TransitionContext) -> TransitionDecision {
        let dur = max(1.0, context.outgoingDuration)
        let cue = max(0, dur - 16.0)
        return TransitionDecision(
            scenario: .fullBlend(bars: 4),
            cueTime: cue,
            duration: 16.0,
            incomingStart: 0,
            tempoRate: 1.0,
            curve: .bassSwap,
            score: 0.9,
            reason: "AI Bass-Swap"
        )
    }

    // MARK: - Local Fallback Decision Planning

    nonisolated static func planLocalFallback(
        sourceTrack: Track,
        sourceAnalysis: TrackAnalysis,
        targetTrack: Track,
        targetAnalysis: TrackAnalysis
    ) -> TransitionPlan {
        let sourceDur = max(10.0, sourceAnalysis.duration)
        let targetDur = max(10.0, targetAnalysis.duration)

        let srcBPM = sourceAnalysis.bpm ?? 120.0
        let tgtBPM = targetAnalysis.bpm ?? 120.0
        let bpmDiff = abs(srcBPM - tgtBPM)
        let bpmRatio = max(srcBPM, tgtBPM) / max(1.0, min(srcBPM, tgtBPM))

        let srcEnergy = sourceAnalysis.energy
        let tgtEnergy = targetAnalysis.energy
        let energyDiff = abs(srcEnergy - tgtEnergy)

        // 1. Calculate Score components
        let rhythmScore = (bpmRatio <= 1.06) ? 1.0 : max(0.0, 1.0 - (bpmDiff / 30.0))
        let harmonicScore = (sourceAnalysis.musicalKey != nil && sourceAnalysis.musicalKey == targetAnalysis.musicalKey) ? 1.0 : 0.6
        let energyScore = max(0.0, 1.0 - energyDiff)
        let structureScore = (sourceAnalysis.outroStart > 0 && targetAnalysis.introEnd > 0) ? 0.9 : 0.6
        let vocalScore = 0.8
        let confidenceScore = Double(min(sourceAnalysis.bpmConfidence, targetAnalysis.bpmConfidence))

        let totalScore = rhythmScore * rhythmWeight
                       + harmonicScore * harmonicWeight
                       + energyScore * energyWeight
                       + structureScore * structureWeight
                       + vocalScore * vocalWeight
                       + confidenceScore * confidenceWeight

        // 2. Select Transition Strategy (Section 6 & 14)
        var strategy: TransitionStrategy
        var reason: String
        var blendDuration: Double
        var sourcePlaybackRate: Double = 1.0
        var targetPlaybackRate: Double = 1.0

        let silenceTail = sourceAnalysis.silenceRegions.first(where: { $0.end >= sourceDur - 1.0 })?.duration ?? 0.0

        if silenceTail > 3.0 {
            strategy = .SILENCE_TRIM
            reason = "Обнаружена пауза в конце трека, выполняется бесшовная обрезка тишины"
            blendDuration = 2.0
        } else if bpmRatio <= 1.08 {
            let avgBPM = (srcBPM + tgtBPM) / 2.0
            sourcePlaybackRate = min(1.06, max(0.94, avgBPM / srcBPM))
            targetPlaybackRate = min(1.06, max(0.94, avgBPM / tgtBPM))
            let gridBar = sourceAnalysis.barDuration ?? (60.0 / avgBPM * 4.0)

            strategy = .BASS_SWAP
            reason = "Бит-синхронизированный DJ Bass-Swap с выравниванием по тактам"
            blendDuration = min(24.0, max(12.0, gridBar * 4.0))
        } else if bpmRatio > 1.25 {
            if tgtEnergy > srcEnergy + 0.3 {
                strategy = .BUILDUP_TO_DROP
                reason = "Разгон энергии к дропу следующего трека"
                blendDuration = 10.0
            } else {
                strategy = .FILTER_TRANSITION
                reason = "High-Pass фильтрация с резонансным срезом"
                blendDuration = 12.0
            }
        } else if energyDiff > 0.40 {
            strategy = .ENERGY_BLEND
            reason = "Плавный энергетический переход с разделением частот"
            blendDuration = 14.0
        } else {
            strategy = .BASS_SWAP
            reason = "DJ Bass-Swap с выравниванием по тактам"
            blendDuration = 16.0
        }

        // 3. Compute Musical Cue Time (Sections 9, 10, 23)
        var cueTime = max(0, sourceDur - blendDuration - silenceTail)
        if let barDur = sourceAnalysis.barDuration, barDur > 0.5 {
            let barIdx = floor(cueTime / barDur)
            cueTime = barIdx * barDur
            if (sourceDur - cueTime) < 2.0 {
                cueTime = max(0, sourceDur - blendDuration)
            }
        }

        // 4. Generate Action Envelopes (Section 15 & 16)
        var actions: [TransitionAction] = []
        let half = blendDuration / 2.0

        switch strategy {
        case .BASS_SWAP, .BEAT_MATCH_EQ:
            actions.append(TransitionAction(time: 0.0, target: "source", parameter: "volume", value: 1.0, duration: 0.0))
            actions.append(TransitionAction(time: half * 0.4, target: "source", parameter: "lowEQ", value: 0.05, duration: half))
            actions.append(TransitionAction(time: blendDuration, target: "source", parameter: "volume", value: 0.0, duration: 0.0))

            actions.append(TransitionAction(time: 0.0, target: "target", parameter: "volume", value: 0.05, duration: 0.0))
            actions.append(TransitionAction(time: 0.0, target: "target", parameter: "lowEQ", value: 0.0, duration: 0.0))
            actions.append(TransitionAction(time: half * 0.6, target: "target", parameter: "lowEQ", value: 1.0, duration: half))
            actions.append(TransitionAction(time: blendDuration, target: "target", parameter: "volume", value: 1.0, duration: 0.0))

        case .FILTER_TRANSITION:
            actions.append(TransitionAction(time: 0.0, target: "source", parameter: "filter", value: 1.0, duration: 0.0))
            actions.append(TransitionAction(time: half, target: "source", parameter: "filter", value: 0.1, duration: half))
            actions.append(TransitionAction(time: 0.0, target: "target", parameter: "volume", value: 0.1, duration: 0.0))
            actions.append(TransitionAction(time: half, target: "target", parameter: "volume", value: 1.0, duration: half))

        default:
            actions.append(TransitionAction(time: 0.0, target: "source", parameter: "volume", value: 1.0, duration: 0.0))
            actions.append(TransitionAction(time: blendDuration, target: "source", parameter: "volume", value: 0.0, duration: blendDuration))
            actions.append(TransitionAction(time: 0.0, target: "target", parameter: "volume", value: 0.0, duration: 0.0))
            actions.append(TransitionAction(time: blendDuration, target: "target", parameter: "volume", value: 1.0, duration: blendDuration))
        }

        return TransitionPlan(
            decision: TransitionDecisionInfo(
                transitionType: strategy.rawValue,
                confidence: totalScore,
                reason: reason
            ),
            sourceTrack: TransitionSourceTrackInfo(
                transitionStart: cueTime,
                transitionEnd: sourceDur
            ),
            targetTrack: TransitionTargetTrackInfo(
                startPosition: targetAnalysis.introStart
            ),
            tempo: TransitionTempoInfo(
                targetBPM: (srcBPM + tgtBPM) / 2.0,
                sourcePlaybackRate: sourcePlaybackRate,
                targetPlaybackRate: targetPlaybackRate
            ),
            actions: actions,
            fallback: TransitionFallbackInfo(
                type: TransitionStrategy.BASS_SWAP.rawValue
            )
        )
    }
}
