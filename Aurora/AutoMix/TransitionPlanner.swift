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

    // MARK: - Per-pair variation (TZ Sections 24, 29)
    //
    // Every measured pair of tracks should get its OWN transition, not a
    // template. A deterministic seed derived from both track IDs drives small
    // musical variations: blend length, curve shapes, reverb depth and entry
    // offsets differ pair to pair, and even the same pair never repeats the
    // exact same transition twice because the seed also mixes in the queue
    // position.

    /// Stable 64-bit seed from the pair + a salt.
    nonisolated private static func variationSeed(
        sourceTrackID: UUID,
        targetTrackID: UUID,
        salt: Int
    ) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        func mix(_ value: UInt64) {
            hash = (hash ^ value) &* 1099511628211
        }
        let combined = sourceTrackID.uuidString + "|" + targetTrackID.uuidString + "|" + String(salt)
        for byte in combined.utf8 { mix(UInt64(byte)) }
        return hash
    }

    nonisolated private static func seededDouble(_ seed: UInt64) -> Double {
        var z = seed
        z = (z ^ (z >> 33)) &* 0xFF51AFD7ED558CCD
        z = (z ^ (z >> 33)) &* 0xC4CEB9FE1A85EC53
        z = z ^ (z >> 33)
        return Double(z % 10_000) / 10_000.0
    }

    // MARK: - Reverb character selection

    /// Chooses the reverb character from the measured audio of the pair, with a
    /// seeded pick between two musical candidates so the same genre does not
    /// always get the identical tail. Upbeat dance material gets short bright
    /// tails that keep the rhythm readable; slow, quiet or heavily vocal
    //  material gets longer, darker rooms.
    nonisolated static func chooseReverbPreset(
        source: TrackAnalysis,
        target: TrackAnalysis,
        seed: UInt64
    ) -> String {
        let avgEnergy = (source.energy + target.energy) / 2
        let knownBPMs = [source.bpm, target.bpm].compactMap { $0 }
        let avgBPM = knownBPMs.isEmpty ? nil : knownBPMs.reduce(0, +) / Double(knownBPMs.count)
        let vocalHeavy = source.vocalRegions.count >= 3 || target.vocalRegions.count >= 3

        var candidates: [String]
        if let bpm = avgBPM, bpm >= 118 {
            // Club material: the tail must not wash out the kick.
            candidates = ["plate", "smallRoom", "mediumRoom"]
        } else if avgEnergy < 0.35 {
            // Slow/quiet: long lush tails sound intentional.
            candidates = ["largeHall", "cathedral", "largeRoom"]
        } else if vocalHeavy {
            candidates = ["mediumChamber", "mediumHall", "largeChamber"]
        } else {
            candidates = ["mediumRoom", "mediumHall", "plate"]
        }

        let index = Int(seededDouble(seed) * Double(candidates.count)) % candidates.count
        return candidates[index]
    }

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

    // MARK: - Smart next-track selection
    //
    // AutoMix should not just blend whatever the queue happens to place next -
    // it should pick, out of a bounded lookahead window of upcoming songs,
    // whichever one actually meshes with the track that is about to end:
    // same or harmonically adjacent Camelot key, and a close enough tempo
    // that the existing beat-match stretch window (+/-6%) can lock them
    // together. This is what makes the transition musically "hit" the key
    // and the beat instead of only depending on whatever a fixed pair
    // happens to measure like.

    /// Highest-scoring upcoming track for a real harmonic/tempo mashup, or
    /// `nil` if nothing in the pool clears a reasonable compatibility bar
    /// (in which case the caller should keep the plain queue order).
    nonisolated static func bestAutoMixCandidate(
        current: TrackAnalysis,
        candidates: [(track: Track, analysis: TrackAnalysis)]
    ) -> Track? {
        guard !candidates.isEmpty else { return nil }

        var best: (track: Track, score: Double)? = nil
        for candidate in candidates {
            let harmonic = harmonicScore(source: current, target: candidate.analysis)
            let rhythm: Double
            if let sourceBPM = current.bpm, let targetBPM = candidate.analysis.bpm {
                rhythm = rhythmScore(sourceBPM: sourceBPM, targetBPM: targetBPM)
            } else {
                rhythm = 0.4
            }
            // Key match weighted higher than tempo: a wrong key clashes far
            // more audibly than a tempo the beat-match stretch can absorb.
            let score = harmonic * 0.6 + rhythm * 0.4
            if best == nil || score > best!.score {
                best = (candidate.track, score)
            }
        }

        guard let winner = best, winner.score >= 0.55 else { return nil }
        return winner.track
    }

    // MARK: - Stream plan override

    /// Remap a plan (local or cloud) to a long, audible, FX-driven blend for
    /// Yandex/HTTP streams: drop the short "silence trim / hard cut" style
    /// strategies and floor the lead time at 14 s so the bass-kill / echo /
    /// crossfade in the stream tap is actually heard.
    nonisolated static func streamOverride(_ plan: TransitionPlan, streamBlend: Bool = true) -> TransitionPlan {
        guard streamBlend else { return plan }
        var strategy = plan.strategy
        switch strategy {
        case .SILENCE_TRIM, .HARD_CUT, .VOCAL_CUT, .DROP_SWITCH, .LOOP_TRANSITION:
            strategy = .BASS_SWAP
        default:
            break
        }
        var actions = plan.actions
        if actions.isEmpty || plan.leadTime < 12 {
            actions = actionEnvelopes(strategy: strategy, duration: max(16, plan.leadTime))
        }
        let leadTime = max(plan.leadTime, 14.0)
        let start = max(0, plan.sourceTrack.transitionStart, plan.cueTime)
        return TransitionPlan(
            decision: TransitionDecisionInfo(
                transitionType: strategy.rawValue,
                confidence: plan.decision.confidence,
                reason: plan.decision.reason + " [stream long-blend]"
            ),
            sourceTrack: TransitionSourceTrackInfo(
                transitionStart: max(0, start),
                transitionEnd: start + leadTime
            ),
            targetTrack: plan.targetTrack,
            tempo: plan.tempo,
            actions: actions,
            fallback: plan.fallback,
            effects: plan.effects
        )
    }

    // MARK: - Local Fallback Decision Planning (offline DSP decision engine)

    /// Builds a complete executable TransitionPlan without any network access.
    /// Runs when Gemini is unavailable, unconfigured or returned garbage, and
    /// also backs `sanitize(...)` when an AI plan cannot be repaired.
    nonisolated static func planLocalFallback(
        sourceTrackID: UUID,
        sourceAnalysis: TrackAnalysis,
        targetTrackID: UUID,
        targetAnalysis: TrackAnalysis,
        streamBlend: Bool = false
    ) -> TransitionPlan {
        let sourceDur = max(8.0, sourceAnalysis.duration)
        let targetDur = max(8.0, targetAnalysis.duration)

        let srcBPM = sourceAnalysis.bpm ?? targetAnalysis.bpm ?? 0
        let tgtBPM = targetAnalysis.bpm ?? sourceAnalysis.bpm ?? 0
        let bothTempiKnown = sourceAnalysis.bpm != nil && targetAnalysis.bpm != nil
        let bpmRatio = bothTempiKnown ? (max(srcBPM, tgtBPM) / max(1, min(srcBPM, tgtBPM))) : 2.0

        let energyDiff = abs(sourceAnalysis.energy - targetAnalysis.energy)

        // Per-pair variation seeds: the same pair never blends identically twice
        // (the salt mixes the track ids differently each planning run).
        let lengthSeed = variationSeed(sourceTrackID: sourceTrackID, targetTrackID: targetTrackID, salt: 1)
        let reverbSeed = variationSeed(sourceTrackID: sourceTrackID, targetTrackID: targetTrackID, salt: 2)
        let depthSeed = variationSeed(sourceTrackID: sourceTrackID, targetTrackID: targetTrackID, salt: 3)

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
            && sourceAnalysis.bpmConfidence >= 0.45
            && targetAnalysis.bpmConfidence >= 0.45
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
            // Apple Music AutoMix: smooth frequency-separated energy blend instead of an abrupt cut
            strategy = .ENERGY_BLEND
            reason = "Плавный частотно-разделенный AutoMix кроссфейд (Apple Music Style)"
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
            // Equally musical candidates: a seeded pick keeps the mix alive so
            // a run of similar pairs does not sound copy-pasted (TZ Section 24).
            let strategySeed = variationSeed(sourceTrackID: sourceTrackID, targetTrackID: targetTrackID, salt: 4)
            let pick = seededDouble(strategySeed)
            if pick < 0.55 {
                strategy = .BASS_SWAP
                reason = "Гармоничный DJ Bass-Swap на границе тактов"
            } else if pick < 0.8 {
                strategy = .BEAT_MATCH_EQ
                reason = "Бит-матчинг с EQ-разделением низа — вариация сведения"
            } else {
                strategy = .ECHO_OUT
                reason = "Вариация: последний акцент уходит в реверб-хвост"
            }
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

        // --- Stream (Yandex/HTTP) override: the fade-out of a streamed track
        // is often detected as "trailing silence", which selected the 1.5 s
        // SILENCE_TRIM and made stream transitions sound like a short, abrupt
        // crossfade with no DJ effects. Streams always get a long, audible,
        // frequency-separated blend (bass kill / echo / energy crossfade) —
        // the in-stream MTAudioProcessingTap renders the FX live.
        if streamBlend {
            let pick = seededDouble(variationSeed(sourceTrackID: sourceTrackID,
                                                  targetTrackID: targetTrackID, salt: 9))
            if strategy == .SILENCE_TRIM || strategy == .HARD_CUT || strategy == .VOCAL_CUT {
                if pick < 0.4 {
                    strategy = .BASS_SWAP
                    reason = "Стрим: длинный DJ bass-swap с глушением низа"
                } else if pick < 0.75 {
                    strategy = .ENERGY_BLEND
                    reason = "Стрим: длинный частотно-разделенный AutoMix"
                } else {
                    strategy = .ECHO_OUT
                    reason = "Стрим: уходящий трек растворяется в эхо-хвосте"
                }
            } else if strategy == .SIMPLE_CROSSFADE {
                strategy = pick < 0.5 ? .BEAT_MATCH_EQ : .ENERGY_BLEND
                reason = "Стрим: расширенное DJ-сведение вместо короткого фейда"
            }
        }

        // --- 3. Musical cue time (TZ Sections 10, 23) ---
        var blendDuration = blendLength(
            for: strategy,
            source: sourceAnalysis,
            sourceDur: sourceDur
        )
        // Per-pair length variation: the same pair must not always blend for
        // exactly the same number of seconds; quantize back to whole bars so
        // the variation stays musical.
        let lengthJitter = 0.8 + seededDouble(lengthSeed) * 0.4   // ±20 %
        if strategy != .SILENCE_TRIM, strategy != .HARD_CUT, strategy != .DROP_SWITCH {
            blendDuration = min(30, max(3, blendDuration * lengthJitter))
            if let bar = sourceAnalysis.barDuration, bar > 0.4 {
                let bars = max(1, (blendDuration / bar).rounded())
                blendDuration = bars * bar
            }
        }
        // Streams must always blend long enough to hear the DJ "заезжание" —
        // floor at 13 s and quantize up to the next whole bar.
        if streamBlend, strategy != .SILENCE_TRIM, strategy != .HARD_CUT {
            blendDuration = max(blendDuration, 13.0)
            if let bar = sourceAnalysis.barDuration, bar > 0.4 {
                let bars = max(1, (blendDuration / bar).rounded(.up))
                blendDuration = min(28, bars * bar)
            } else {
                blendDuration = min(28, max(blendDuration, 16.0))
            }
        }

        var cueTime: TimeInterval
        var hasExplicitOutro = false

        switch strategy {
        case .VOCAL_CUT:
            if let vocal = sourceAnalysis.lastVocalEnd, (sourceDur - vocal) >= 4.0 {
                cueTime = vocal
                hasExplicitOutro = true
            } else {
                cueTime = max(0, sourceDur - blendDuration)
            }
        case .SILENCE_TRIM:
            cueTime = max(0, (sourceAnalysis.trailingSilence?.start ?? sourceDur) - 1.0)
            hasExplicitOutro = true
        case .BUILDUP_TO_DROP:
            if let buildUp = sourceAnalysis.buildUps.last {
                cueTime = max(buildUp.start, sourceDur - blendDuration - 2)
            } else {
                cueTime = max(0, sourceDur - blendDuration)
            }
        case .DROP_SWITCH:
            cueTime = max(0, sourceDur - min(blendDuration, 4))
        default:
            // Prefer the detected outro (can start 15-32s before track end to skip dead repetitive outro)
            if sourceAnalysis.outroStart > 1 && (sourceDur - sourceAnalysis.outroStart) >= 6.0 {
                cueTime = sourceAnalysis.outroStart
                hasExplicitOutro = true
            } else {
                cueTime = max(0, sourceDur - blendDuration)
            }
        }

        // Snap the cue to the nearest downbeat so the switch lands on the grid.
        if strategy != .SILENCE_TRIM, let snapped = sourceAnalysis.nearestDownbeat(to: cueTime) {
            cueTime = snapped
        }
        // Only clamp to the tail if no explicit vocal/outro boundary was detected
        if !hasExplicitOutro {
            cueTime = max(cueTime, sourceDur - blendDuration - 2)
        }
        cueTime = min(max(0, cueTime), max(0, sourceDur - 1.5))

        // --- 4. Action envelopes (TZ Sections 11, 15, 16) ---
        // (built inside the return; depth-scaled per pair below)

        // --- 5. Phase-aligned target entry (TZ Section 9) ---
        // The incoming track's first beat must land on the outgoing track's
        // downbeat, not at a random sample. Shift the target's start position so
        // its beat grid lines up with the source's grid at the cue.
        let targetStart = phaseAlignedStart(
            cueTime: cueTime,
            blendDuration: blendDuration,
            sourceRate: sourceRate,
            targetRate: targetRate,
            source: sourceAnalysis,
            target: targetAnalysis
        )

        let fallbackStrategy: TransitionStrategy
        switch strategy {
        case .BASS_SWAP, .BEAT_MATCH, .BEAT_MATCH_EQ: fallbackStrategy = .SIMPLE_CROSSFADE
        case .BUILDUP_TO_DROP, .DROP_SWITCH: fallbackStrategy = .FILTER_TRANSITION
        case .SILENCE_TRIM: fallbackStrategy = .HARD_CUT
        default: fallbackStrategy = .SIMPLE_CROSSFADE
        }

        // Reverb character from the measured pair (TZ Section 29): club BPMs
        // get short readable tails, quiet material gets lush halls, vocal-heavy
        // pairs get chambers - with a seeded pick inside the candidate set so
        // consecutive transitions of the same genre differ.
        let reverbPreset = chooseReverbPreset(
            source: sourceAnalysis,
            target: targetAnalysis,
            seed: reverbSeed
        )

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
                startPosition: targetStart
            ),
            tempo: TransitionTempoInfo(
                targetBPM: tgtBPM > 0 ? tgtBPM : (srcBPM > 0 ? srcBPM : 120),
                sourcePlaybackRate: sourceRate,
                targetPlaybackRate: targetRate
            ),
            actions: varyEnvelopeDepth(
                actionEnvelopes(strategy: strategy, duration: blendDuration),
                seed: depthSeed,
                strategy: strategy
            ),
            fallback: TransitionFallbackInfo(type: fallbackStrategy.rawValue),
            effects: TransitionEffects(reverbPreset: reverbPreset)
        )
    }

    /// Scales the effect depths (reverb, EQ cuts) by a seeded factor so the
    /// character of consecutive transitions varies even for the same strategy.
    nonisolated private static func varyEnvelopeDepth(
        _ actions: [TransitionAction],
        seed: UInt64,
        strategy: TransitionStrategy
    ) -> [TransitionAction] {
        // Long-tail strategies vary more; plain crossfades stay predictable.
        let factor = strategy == .ECHO_OUT || strategy == .FILTER_TRANSITION
            ? 0.6 + seededDouble(seed) * 0.8
            : 0.85 + seededDouble(seed) * 0.3
        return actions.map { action in
            guard action.parameter == "reverb" || action.parameter == "lowEQ" || action.parameter == "highEQ" else {
                return action
            }
            return TransitionAction(
                time: action.time,
                target: action.target,
                parameter: action.parameter,
                value: min(1, max(0, action.value * factor)),
                duration: action.duration
            )
        }
    }

    /// Chooses the target's start position so that (with the plan's playback
    /// rates) its beat grid is in phase with the source's grid at the cue: the
    /// beat that plays when the target becomes audible lands on the source's
    /// nearest downbeat. Returns 0 when the beat grids are unknown.
    nonisolated static func phaseAlignedStart(
        cueTime: TimeInterval,
        blendDuration: TimeInterval,
        sourceRate: Double,
        targetRate: Double,
        source: TrackAnalysis,
        target: TrackAnalysis
    ) -> Double {
        guard let sourceBeatInterval = source.bpm.map({ 60.0 / max(1, $0) }),
              let targetBeatInterval = target.bpm.map({ 60.0 / max(1, $0) }) else { return 0 }

        // Wall-clock beat period of each lane while stretched.
        let sourcePeriod = sourceBeatInterval / max(0.5, sourceRate)
        let targetPeriod = targetBeatInterval / max(0.5, targetRate)
        guard sourcePeriod.isFinite, targetPeriod.isFinite else { return 0 }

        // Phase of the source grid at the moment the blend starts.
        let sourcePhase = cueTime.truncatingRemainder(dividingBy: sourcePeriod)

        // The target becomes audible part-way through the blend (its volume
        // ramp crosses the source's about mid-way); align around that moment.
        let audibleAt = cueTime + blendDuration * 0.5
        let sourcePhaseAtAudible = audibleAt.truncatingRemainder(dividingBy: sourcePeriod)

        // Find the target's nearest beat-position to align onto the source's
        // phase: pick the next target grid point whose phase matches.
        let targetStart = target.firstBeat ?? 0
        let targetPhase = (targetStart).truncatingRemainder(dividingBy: targetPeriod)
        var shift = sourcePhaseAtAudible - targetPhase
        if shift < 0 { shift += targetPeriod }

        // Keep the shift inside one beat - nudging a whole beat off just moves
        // the entry point without changing the phase relationship.
        if shift > targetPeriod / 2 { shift -= targetPeriod }
        if shift < -targetPeriod / 2 { shift += targetPeriod }

        let aligned = max(0, targetStart + shift)
        // Phase alignment is a nicety, not a goal: never dive deep into the
        // target just to line up grids. DJs bring a track in at its intro; a
        // mid-track entry sounds like the player skipped into the song.
        let maxEntry: Double = 8.0
        let clamped = min(aligned, maxEntry)
        // If the phase shift points before the intro ends, start at the intro
        // boundary instead (phase alignment gives up, musicality wins).
        let introFloor = target.introEnd > 2 ? min(target.introEnd, maxEntry) : 0
        return max(clamped, introFloor)
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
        case .HARD_CUT, .DROP_SWITCH: base = 3.5
        case .VOCAL_CUT: base = 3.5
        case .ECHO_OUT: base = 5.0
        case .FILTER_TRANSITION: base = 5.0
        case .BUILDUP_TO_DROP: base = 10
        case .ENERGY_BLEND: base = 14
        case .BEAT_MATCH_EQ: base = sourceDur > 120 ? 20 : 16
        case .BASS_SWAP: base = sourceDur > 120 ? 22 : 18
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
            // Reverb swell on the outgoing bass hand-off (TZ Section 29): this was
            // previously only ever set for ECHO_OUT, so every bass-swap / beat-match
            // transition ran with the reverb wetness pinned at 0 despite loading a
            // preset - the mix sounded completely dry no matter what character was
            // chosen. A short swell right on the low-end swap makes the DJ-style
            // "tuck under" audible.
            actions.append(TransitionAction(time: 0, target: "source", parameter: "reverb", value: 0.0, duration: 0))
            actions.append(TransitionAction(time: half * 0.4, target: "source", parameter: "reverb", value: 0.35, duration: half * 0.6))
            actions.append(TransitionAction(time: duration * 0.85, target: "source", parameter: "reverb", value: 0.0, duration: duration * 0.15))

            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 0.0, duration: duration * 0.55))
            actions.append(TransitionAction(time: duration * 0.55, target: "target", parameter: "volume", value: 0.7, duration: duration * 0.45))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "lowEQ", value: 0.0, duration: half * 0.6))
            actions.append(TransitionAction(time: half * 0.6, target: "target", parameter: "lowEQ", value: 1.0, duration: half * 0.4))

        case .FILTER_TRANSITION:
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: half))
            actions.append(TransitionAction(time: half, target: "source", parameter: "volume", value: 0.35, duration: half))
            actions.append(TransitionAction(time: 0, target: "source", parameter: "filter", value: 1.0, duration: 0))
            actions.append(TransitionAction(time: half, target: "source", parameter: "filter", value: 0.1, duration: half))
            // The filter sweep reads as a real DJ filter-out when a matching reverb
            // tail rises behind it instead of running bone dry.
            actions.append(TransitionAction(time: 0, target: "source", parameter: "reverb", value: 0.0, duration: 0))
            actions.append(TransitionAction(time: half, target: "source", parameter: "reverb", value: 0.5, duration: half))
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
            // A light reverb tail masks the vocal cut instead of it landing dry.
            actions.append(TransitionAction(time: duration * 0.6, target: "source", parameter: "reverb", value: 0.3, duration: duration * 0.25))
            actions.append(TransitionAction(time: duration * 0.85, target: "source", parameter: "reverb", value: 0.0, duration: duration * 0.15))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 0.0, duration: 0))
            actions.append(TransitionAction(time: duration * 0.45, target: "target", parameter: "volume", value: 0.75, duration: duration * 0.45))

        case .ECHO_OUT:
            // Last hit of the source dissolves into a growing plate reverb
            // while the target enters clean (TZ Section 14 ECHO_OUT).
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: duration * 0.5))
            actions.append(TransitionAction(time: duration * 0.5, target: "source", parameter: "volume", value: 0.5, duration: duration * 0.4))
            actions.append(TransitionAction(time: duration * 0.9, target: "source", parameter: "volume", value: 0.0, duration: duration * 0.1))
            actions.append(TransitionAction(time: 0, target: "source", parameter: "reverb", value: 0.0, duration: 0))
            actions.append(TransitionAction(time: duration * 0.25, target: "source", parameter: "reverb", value: 0.55, duration: duration * 0.5))
            actions.append(TransitionAction(time: duration * 0.75, target: "source", parameter: "reverb", value: 0.95, duration: duration * 0.25))
            actions.append(TransitionAction(time: 0, target: "source", parameter: "highEQ", value: 0.8, duration: duration))
            actions.append(TransitionAction(time: duration * 0.55, target: "target", parameter: "volume", value: 0.0, duration: 0))
            actions.append(TransitionAction(time: duration * 0.9, target: "target", parameter: "volume", value: 1.0, duration: duration * 0.1))

        case .ENERGY_BLEND:
            // Energy rides across: source eases down through the mid, target
            // rises over the whole window, low-end crosses at the midpoint.
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: duration * 0.7))
            actions.append(TransitionAction(time: duration * 0.7, target: "source", parameter: "volume", value: 0.0, duration: duration * 0.3))
            actions.append(TransitionAction(time: 0, target: "source", parameter: "lowEQ", value: 0.8, duration: duration * 0.5))
            actions.append(TransitionAction(time: duration * 0.5, target: "source", parameter: "lowEQ", value: 0.05, duration: duration * 0.5))
            // Reverb crossover sits right where the energy actually hands off.
            actions.append(TransitionAction(time: duration * 0.5, target: "source", parameter: "reverb", value: 0.0, duration: duration * 0.2))
            actions.append(TransitionAction(time: duration * 0.7, target: "source", parameter: "reverb", value: 0.4, duration: duration * 0.3))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 0.0, duration: duration * 0.8))
            actions.append(TransitionAction(time: duration * 0.8, target: "target", parameter: "volume", value: 1.0, duration: duration * 0.2))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "lowEQ", value: 0.0, duration: duration * 0.4))
            actions.append(TransitionAction(time: duration * 0.4, target: "target", parameter: "lowEQ", value: 1.0, duration: duration * 0.6))

        case .LOOP_TRANSITION, .INSTRUMENTAL_OVERLAY:
            // The incoming phrase carries over the source's tail with a light
            // reverb smear on the way out.
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: duration * 0.75))
            actions.append(TransitionAction(time: duration * 0.75, target: "source", parameter: "volume", value: 0.0, duration: duration * 0.25))
            actions.append(TransitionAction(time: duration * 0.4, target: "source", parameter: "reverb", value: 0.3, duration: duration * 0.5))
            actions.append(TransitionAction(time: 0, target: "target", parameter: "volume", value: 0.0, duration: duration * 0.6))
            actions.append(TransitionAction(time: duration * 0.6, target: "target", parameter: "volume", value: 1.0, duration: duration * 0.4))

        default:
            actions.append(TransitionAction(time: 0, target: "source", parameter: "volume", value: 1.0, duration: duration * 0.85))
            actions.append(TransitionAction(time: duration * 0.85, target: "source", parameter: "volume", value: 0.0, duration: duration * 0.15))
            // Even the plain crossfade gets a small reverb lift right as it fades
            // out, so a simple transition still reads as a deliberate DJ blend
            // instead of two tracks with silent, unrelated reverb units.
            actions.append(TransitionAction(time: duration * 0.75, target: "source", parameter: "reverb", value: 0.0, duration: duration * 0.1))
            actions.append(TransitionAction(time: duration * 0.85, target: "source", parameter: "reverb", value: 0.28, duration: duration * 0.15))
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
        // Keep blend length intact; only clamp to track end if not an early outro
        if sourceDur - end > 2 {
            let blendLength = end - cue
            let isEarlyOutro = cue < sourceDur - blendLength - 3
            if !isEarlyOutro {
                end = sourceDur
                cue = min(cue, max(0, sourceDur - blendLength - 2))
            }
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

        // Reverb character: keep the AI's valid choice, otherwise derive it from
        // the measured pair like the local planner does.
        var effects = plan.effects
        if !TransitionEffects.reverbPresets.contains(effects.reverbPreset) {
            effects.reverbPreset = chooseReverbPreset(
                source: sourceAnalysis,
                target: targetAnalysis,
                seed: UInt64(truncatingIfNeeded: Int(sourceAnalysis.duration * 1000) + Int(targetAnalysis.duration * 1000))
            )
        }

        return TransitionPlan(
            decision: TransitionDecisionInfo(
                transitionType: strategy.rawValue,
                confidence: min(1, max(0.05, confidence.isFinite ? confidence : 0.5)),
                reason: reason
            ),
            sourceTrack: TransitionSourceTrackInfo(transitionStart: cue, transitionEnd: end),
            targetTrack: TransitionTargetTrackInfo(
                startPosition: max(
                    0,
                    phaseAlignedStart(
                        cueTime: cue,
                        blendDuration: end - cue,
                        sourceRate: sRate,
                        targetRate: tRate,
                        source: sourceAnalysis,
                        target: targetAnalysis
                    )
                )
            ),
            tempo: TransitionTempoInfo(targetBPM: targetBPM, sourcePlaybackRate: sRate, targetPlaybackRate: tRate),
            actions: actions,
            fallback: TransitionFallbackInfo(type: plan.fallback.type.isEmpty ? TransitionStrategy.SIMPLE_CROSSFADE.rawValue : plan.fallback.type),
            effects: effects
        )
    }
}
