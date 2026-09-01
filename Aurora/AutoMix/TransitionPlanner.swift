import Foundation

// MARK: - Transition planning

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

    /// A difficult junction can hold a clean musical phrase from deck A until
    /// deck B reaches its downbeat. Both values are snapped to the analysed grid.
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
    /// Kept for source compatibility. AutoMix deliberately ignores a manual
    /// ceiling and chooses its phrase length from the music.
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
    static let keyWeight: Float = 0.34
    static let tempoWeight: Float = 0.34
    static let vocalWeight: Float = 0.17
    static let sectionWeight: Float = 0.10
    static let genreWeight: Float = 0.05

    nonisolated static func plan(_ context: TransitionContext) -> TransitionDecision {
        let total = max(1, context.outgoingDuration)

        switch context.mode {
        case .off:
            return TransitionDecision(scenario: .gapRemoval, cueTime: total, duration: 0, incomingStart: 0, tempoRate: 1, curve: .cut, score: 0, reason: "Переходы выключены")
        case .gapless:
            return gapRemoval(context, reason: "Убрана пауза")
        case .crossfade:
            return simpleCrossfade(context, seconds: context.crossfadeDuration, score: 0.5, reason: "Кроссфейд")
        case .automix:
            break
        }

        guard let outgoing = context.outgoing, let incoming = context.incoming else {
            return simpleCrossfade(context, seconds: 4, score: 0.4, reason: "Анализ не успел завершиться")
        }

        if !outgoing.hasSteadyBeat && !incoming.hasSteadyBeat {
            return gapRemoval(context, reason: "У треков нет устойчивого бита")
        }
        guard outgoing.hasSteadyBeat, incoming.hasSteadyBeat,
              let rate = TimeStretchEngine.rate(from: incoming.bpm, to: outgoing.bpm) else {
            return simpleCrossfade(context, seconds: 4.5, score: 0.45, reason: "BPM нельзя свести без искажения")
        }

        var camelotDistance = 12
        if let first = outgoing.camelot, let second = incoming.camelot {
            camelotDistance = first.distance(to: second)
        }
        let keyScore = CamelotWheel.compatibility(outgoing.camelot, incoming.camelot)
        let tempoScore = Float(max(0, 1 - Double(abs(rate - 1)) / 0.10))

        // Enter B after silence, exactly on its nearest downbeat.
        var incomingStart = incoming.introEnd ?? 0
        if let breakdown = incoming.cuePoints.first(where: {
            $0.kind == .breakdownStart && $0.time > 8 && $0.time < 90
        }), incoming.energy(at: breakdown.time) < 0.55 {
            incomingStart = breakdown.time
        }
        incomingStart = nearestDownbeat(in: incoming, to: incomingStart) ?? incomingStart
        incomingStart = max(0, min(incomingStart, max(0, incoming.duration - 20)))

        let entryEnergy = incoming.energy(from: incomingStart, to: incomingStart + 8)
        let sectionScore: Float = entryEnergy < 0.55 ? 1 : (entryEnergy < 0.80 ? 0.65 : 0.35)

        // First estimate the junction, then let phrase quality select 4, 8 or
        // 16 bars. There is intentionally no user duration knob in AutoMix.
        let provisionalBar = outgoing.barDuration ?? 2
        let provisionalCue = max(total * 0.40, outgoing.outroStart ?? (total - provisionalBar * 8))
        let outgoingJunction = outgoing.energy(from: provisionalCue, to: min(total, provisionalCue + provisionalBar * 8))
        let incomingJunction = incoming.energy(from: incomingStart, to: incomingStart + provisionalBar * 8)
        let vocalClash = outgoingJunction > 0.78 && incomingJunction > 0.78
        let vocalScore: Float = vocalClash ? 0.15 : 1

        let genreScore: Float
        switch context.sameGenre {
        case .some(true): genreScore = 1
        case .some(false): genreScore = 0.5
        case nil: genreScore = 0.7
        }

        let score = min(1, max(0,
            keyWeight * keyScore
            + tempoWeight * tempoScore
            + vocalWeight * vocalScore
            + sectionWeight * sectionScore
            + genreWeight * genreScore
        ))

        var bars: Int
        if camelotDistance <= 1 && !vocalClash && score >= 0.72 {
            bars = 16
        } else if score >= 0.52 {
            bars = 8
        } else {
            bars = 4
        }

        let barDuration = outgoing.barDuration ?? 2
        let available = min(30, max(4, total * 0.30))
        while bars > 4 && Double(bars) * barDuration > available { bars /= 2 }
        let duration = min(Double(bars) * barDuration, available)

        var cue = outgoing.outroStart ?? (total - duration)
        cue = max(total * 0.40, cue)
        cue = min(cue, max(0, total - duration))
        cue = nearestDownbeat(in: outgoing, to: cue) ?? cue
        cue = max(0, min(cue, max(0, total - 1)))

        // Harmonic/vocal/BPM difficulty no longer disables DJ mixing. It makes
        // the phrase shorter and enables a 2-4 bar beat loop plus stronger FX,
        // which is how a DJ holds the groove until the next downbeat arrives.
        let tempoShift = abs(Double(rate) - 1)
        let difficult = camelotDistance > 1 || vocalClash || tempoShift > 0.025
        var loopStart: TimeInterval?
        var loopDuration: TimeInterval = 0
        if difficult {
            loopStart = lastDownbeat(in: outgoing, atOrBefore: cue) ?? cue
            loopDuration = min(duration, barDuration * Double(bars >= 8 ? 4 : 2))
        }

        return TransitionDecision(
            scenario: .fullBlend(bars: bars),
            cueTime: cue,
            duration: duration,
            incomingStart: incomingStart,
            tempoRate: rate,
            curve: .bassSwap,
            score: score,
            reason: "Авто: \(Int(outgoing.bpm.rounded())) → \(Int(incoming.bpm.rounded())) BPM, \(bars) такт., \(difficult ? "beat-loop + FX" : "гармоническое сведение")",
            outgoingLoopStart: loopStart,
            outgoingLoopDuration: loopDuration
        )
    }

    nonisolated private static func nearestDownbeat(in analysis: TrackAnalysis, to time: TimeInterval) -> TimeInterval? {
        analysis.downbeats.min(by: { abs($0 - time) < abs($1 - time) })
    }

    nonisolated private static func lastDownbeat(in analysis: TrackAnalysis, atOrBefore time: TimeInterval) -> TimeInterval? {
        analysis.downbeats.last(where: { $0 <= time + 0.02 })
    }

    nonisolated private static func simpleCrossfade(_ context: TransitionContext, seconds: TimeInterval, score: Float, reason: String) -> TransitionDecision {
        let total = max(1, context.outgoingDuration)
        var duration = seconds <= 0 ? 4 : seconds
        duration = min(max(3, duration), 6)
        duration = min(duration, max(1, total * 0.33))
        let silence = trailingDeadAir(context.outgoing, total: total)
        let cue = max(0, min(total - duration - silence, total - duration))
        var start = context.incoming?.introEnd ?? 0
        start = min(max(0, start), 12)
        if let incoming = context.incoming { start = nearestDownbeat(in: incoming, to: start) ?? start }
        return TransitionDecision(scenario: .crossfade, cueTime: cue, duration: duration, incomingStart: start, tempoRate: 1, curve: .dissolve, score: score, reason: reason)
    }

    nonisolated private static func gapRemoval(_ context: TransitionContext, reason: String) -> TransitionDecision {
        let total = max(1, context.outgoingDuration)
        let silence = trailingDeadAir(context.outgoing, total: total)
        let cue = max(0, total - max(0.4, silence))
        let start = min(max(0, context.incoming?.introEnd ?? 0), 12)
        return TransitionDecision(scenario: .gapRemoval, cueTime: cue, duration: 0.4, incomingStart: start, tempoRate: 1, curve: .cut, score: 0.3, reason: reason)
    }

    nonisolated private static func trailingDeadAir(_ analysis: TrackAnalysis?, total: TimeInterval) -> TimeInterval {
        guard let analysis, let outro = analysis.outroStart else { return 0 }
        return max(0, min(total - outro, 12))
    }
}
