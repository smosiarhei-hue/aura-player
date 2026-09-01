import Foundation

// MARK: - Transition planning
//
// Multi-factor scoring between the outgoing track A and the incoming track B:
// harmonic compatibility (Camelot), tempo distance, vocal density at the
// junction, the section B starts on, and optionally the genre pair.
//
// The result is one of three scenarios, exactly as Apple describes AutoMix:
// a real beat-matched blend, a plain crossfade, or just removing the gap.
//
// Deliberately self-contained: it depends only on the analysis types, so it is
// testable without an audio engine or a player.

nonisolated enum AutoMixMode: String, Sendable {
    case automix
    case crossfade
    case gapless
    case off
}

nonisolated enum BlendCurve: String, Sendable {
    /// Full DJ blend: low end swapped between lanes so basses never stack.
    case bassSwap
    /// Equal-power crossfade.
    case dissolve
    /// No blend at all, only dead air removed.
    case cut
}

nonisolated enum TransitionScenario: Sendable, Equatable {
    case fullBlend(bars: Int)
    case crossfade
    case gapRemoval
}

nonisolated struct TransitionDecision: Sendable {
    var scenario: TransitionScenario
    /// Absolute time in the outgoing track where the blend starts.
    var cueTime: TimeInterval
    /// Blend length in seconds.
    var duration: TimeInterval
    /// Where the incoming track starts playing, skipping a quiet intro.
    var incomingStart: TimeInterval
    /// Rate for the incoming lane. 1 means no stretching.
    var tempoRate: Float
    var curve: BlendCurve
    /// 0...1 musical match score, useful for UI and debugging.
    var score: Float
    var reason: String

    var isBeatMatched: Bool {
        if case .fullBlend = scenario { return true }
        return false
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
    /// User setting from the Crossfade slider.
    var crossfadeDuration: TimeInterval
    /// Hard ceiling for a blend, from settings.
    var maxDuration: TimeInterval
    /// nil when genre tags are unavailable.
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
    // Weights: key and tempo high, vocals and section medium, genre low.
    static let keyWeight: Float = 0.34
    static let tempoWeight: Float = 0.34
    static let vocalWeight: Float = 0.17
    static let sectionWeight: Float = 0.10
    static let genreWeight: Float = 0.05

    static let minBlendBars = 8
    static let maxBlendBars = 16

    nonisolated static func plan(_ context: TransitionContext) -> TransitionDecision {
        let total = max(1, context.outgoingDuration)

        switch context.mode {
        case .off:
            return TransitionDecision(
                scenario: .gapRemoval,
                cueTime: total,
                duration: 0,
                incomingStart: 0,
                tempoRate: 1,
                curve: .cut,
                score: 0,
                reason: "Transitions off"
            )
        case .gapless:
            return gapRemoval(context, reason: "Gapless mode")
        case .crossfade:
            return simpleCrossfade(
                context,
                seconds: context.crossfadeDuration,
                score: 0.5,
                reason: "Crossfade mode"
            )
        case .automix:
            break
        }

        guard let outgoing = context.outgoing, let incoming = context.incoming else {
            return simpleCrossfade(
                context,
                seconds: context.crossfadeDuration,
                score: 0.4,
                reason: "Analysis not ready"
            )
        }

        // Neither side has a pulse: ballads, classical, spoken word.
        if !outgoing.hasSteadyBeat && !incoming.hasSteadyBeat {
            return gapRemoval(context, reason: "No steady beat on either track")
        }
        if !outgoing.hasSteadyBeat || !incoming.hasSteadyBeat {
            return simpleCrossfade(context, seconds: 4.5, score: 0.45, reason: "One track has no steady beat")
        }

        // Factor 1: harmonic compatibility.
        var camelotDistance = 12
        if let first = outgoing.camelot, let second = incoming.camelot {
            camelotDistance = first.distance(to: second)
        }
        let keyScore = CamelotWheel.compatibility(outgoing.camelot, incoming.camelot)

        // Factor 2: how much stretching the beat match needs.
        let rate = TimeStretchEngine.rate(from: incoming.bpm, to: outgoing.bpm)
        var tempoScore: Float = 0.1
        if let rate {
            tempoScore = Float(max(0, 1 - Double(abs(rate - 1)) / 0.10))
        }

        // Where the incoming track should enter: after its quiet intro, or on a
        // breakdown, always snapped to a bar start.
        var incomingStart = incoming.introEnd ?? 0
        if let breakdown = incoming.cuePoints.first(where: {
            $0.kind == .breakdownStart && $0.time > 12 && $0.time < 90
        }), incoming.energy(at: breakdown.time) < 0.5 {
            incomingStart = min(incomingStart <= 0.5 ? breakdown.time : incomingStart, breakdown.time)
        }
        incomingStart = incoming.nearestDownbeat(to: incomingStart, tolerance: 4) ?? incomingStart
        incomingStart = max(0, min(incomingStart, max(0, incoming.duration - 30)))

        // Factor 4: does B enter on something clean rather than a full chorus?
        let entryEnergy = incoming.energy(from: incomingStart, to: incomingStart + 8)
        let sectionScore: Float = entryEnergy < 0.55 ? 1.0 : (entryEnergy < 0.80 ? 0.6 : 0.3)

        // Overlap length: 8 bars normally, 16 when both sides are dense enough
        // to carry a long blend.
        let outroEnergy = outgoing.energy(from: max(0, total - 30), to: total)
        let entryBody = incoming.energy(from: incomingStart, to: incomingStart + 16)
        let bars = (outroEnergy > 0.60 && entryBody > 0.45) ? maxBlendBars : minBlendBars

        let bar = outgoing.barDuration ?? 2.0
        var duration = Double(bars) * bar
        duration = min(duration, max(4, context.maxDuration))
        duration = min(duration, total * 0.33)
        duration = max(4, duration)

        // Cue point in A: its outro if we found one, otherwise just before the
        // end. Never earlier than 40 % into the track, always on a bar start.
        var cue = outgoing.outroStart ?? (total - duration)
        cue = max(total * 0.40, cue)
        cue = min(cue, max(0, total - duration))
        cue = outgoing.nearestDownbeat(to: cue, tolerance: 4) ?? cue
        cue = max(0, min(cue, max(0, total - 1)))

        // Factor 3: vocals on both sides of the junction clash badly.
        let outgoingJunction = outgoing.energy(from: cue, to: cue + duration)
        let incomingJunction = incoming.energy(from: incomingStart, to: incomingStart + duration)
        let vocalClash = outgoingJunction > 0.78 && incomingJunction > 0.78
        let vocalScore: Float = vocalClash ? 0.15 : 1.0

        // Factor 5: genre pair, if the library has tags.
        let genreScore: Float
        switch context.sameGenre {
        case .some(true): genreScore = 1.0
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

        // Full blend only when the keys sit next to each other on the wheel,
        // the stretch is inside the limits and the vocals do not collide.
        if let rate, camelotDistance <= 1, !vocalClash {
            return TransitionDecision(
                scenario: .fullBlend(bars: bars),
                cueTime: cue,
                duration: duration,
                incomingStart: incomingStart,
                tempoRate: rate,
                curve: .bassSwap,
                score: score,
                reason: "Beat match: "
                    + outgoing.camelotPosition + " -> " + incoming.camelotPosition
                    + ", " + String(Int(outgoing.bpm.rounded())) + " / "
                    + String(Int(incoming.bpm.rounded())) + " BPM, "
                    + String(bars) + " bars"
            )
        }

        let reason: String
        if vocalClash {
            reason = "Vocals on both sides of the junction"
        } else if rate == nil {
            reason = "Tempo gap too wide to stretch"
        } else {
            reason = "Keys too far apart on the wheel"
        }

        return simpleCrossfade(
            context,
            seconds: max(3, min(6, context.crossfadeDuration)),
            score: score,
            reason: reason
        )
    }

    // MARK: - Fallbacks

    nonisolated private static func simpleCrossfade(
        _ context: TransitionContext,
        seconds: TimeInterval,
        score: Float,
        reason: String
    ) -> TransitionDecision {
        let total = max(1, context.outgoingDuration)
        var duration = seconds <= 0 ? 4 : seconds
        duration = min(max(3, duration), 6)
        duration = min(duration, max(1, total * 0.33))

        let silence = trailingDeadAir(context.outgoing, total: total)
        var cue = total - duration - silence
        cue = max(0, min(cue, max(0, total - duration)))

        var start = context.incoming?.introEnd ?? 0
        start = min(max(0, start), 12)
        if let incoming = context.incoming {
            start = incoming.nearestDownbeat(to: start, tolerance: 2) ?? start
        }

        return TransitionDecision(
            scenario: .crossfade,
            cueTime: cue,
            duration: duration,
            incomingStart: start,
            tempoRate: 1,
            curve: .dissolve,
            score: score,
            reason: reason
        )
    }

    nonisolated private static func gapRemoval(
        _ context: TransitionContext,
        reason: String
    ) -> TransitionDecision {
        let total = max(1, context.outgoingDuration)
        let silence = trailingDeadAir(context.outgoing, total: total)
        let cue = max(0, total - max(0.4, silence))
        var start = context.incoming?.introEnd ?? 0
        start = min(max(0, start), 12)

        return TransitionDecision(
            scenario: .gapRemoval,
            cueTime: cue,
            duration: 0.4,
            incomingStart: start,
            tempoRate: 1,
            curve: .cut,
            score: 0.3,
            reason: reason
        )
    }

    /// Everything after the closing decline is dead air the transition can
    /// swallow instead of making the listener sit through it.
    nonisolated private static func trailingDeadAir(
        _ analysis: TrackAnalysis?,
        total: TimeInterval
    ) -> TimeInterval {
        guard let analysis, let outro = analysis.outroStart else { return 0 }
        return max(0, min(total - outro, 12))
    }
}
