@preconcurrency import AVFoundation
import Foundation

// MARK: - Beatgrid sample-accurate sync
//
// The missing piece between "the planner knows the grids" and "the listener
// feels the transition": the incoming deck must be *scheduled* so that its
// downbeat is rendered at the exact host time of the outgoing deck's cue
// downbeat. Starting the idle player with `at: nil` begins playback on the
// next render cycle — up to ~30 ms late — and, worse, at an arbitrary file
// position chosen for musicality, which lands anywhere inside a beat. After
// a 16-second blend the two beat grids are then half a beat apart even when
// their tempi were stretched to match.
//
// This file is nonisolated stateless math over the analysis model, so it
// can be unit-tested and called from any actor. PlayerCore owns the actual
// node scheduling.

nonisolated struct BeatgridArm: Sendable {
    /// Frame inside the incoming file where playback starts (its entry beat).
    let incomingStartFrame: AVAudioFramePosition
    /// Seconds inside the incoming file where playback starts.
    let incomingEntryTime: TimeInterval
    /// Seconds inside the outgoing file where the blend begins (cue downbeat).
    let cueTime: TimeInterval
    /// Delay before the incoming deck's first sample is rendered, in seconds.
    let delay: TimeInterval
    /// Confirmed wall-clock beat period of the blend (identical on both decks
    /// once the tempo rates are applied).
    let beatPeriod: TimeInterval
    /// Source lane playback rate that is already/being applied.
    let sourceRate: Double
    /// Incoming lane playback rate.
    let targetRate: Double
    /// True when both grids are actually locked (beat period matches within
    /// 2% and both decks expose a usable beat grid).
    let locked: Bool
}

nonisolated enum BeatgridSync {
    /// Maximum start delay we accept for a scheduled entry. The transition
    /// watcher begins arming ~3.5 s before the cue, so 8 s leaves headroom
    /// while never scheduling seconds of silent-but-running playback.
    static let maxArmDelay: TimeInterval = 8.0
    /// Skip entries deeper than this into the incoming song — DJs bring a
    /// track in at its intro, never mid-verse (mirrors TransitionPlanner).
    static let maxEntrySeconds: TimeInterval = 16.0

    /// Compute the sample-accurate arm for a grid-synced transition.
    ///
    /// - Parameters:
    ///   - source: analysis of the outgoing track (file-time beats, bpm).
    ///   - target: analysis of the incoming track.
    ///   - sourceFileTime: current sounding position inside the outgoing file.
    ///   - cueTime: planner-chosen blend start (file time, source track).
    ///   - blendDuration: blend length — used to sanity-check the runway.
    ///   - sourceRate/targetRate: per-lane playback rates (tempo lock).
    ///   - targetFile: incoming audio file, for frame conversion/validation.
    static func arm(
        source: TrackAnalysis,
        target: TrackAnalysis,
        sourceFileTime: TimeInterval,
        cueTime: TimeInterval,
        blendDuration: TimeInterval,
        sourceRate: Double,
        targetRate: Double,
        sourceFileSampleRate: Double,
        targetFileSampleRate: Double,
        targetFileLengthFrames: AVAudioFramePosition
    ) -> BeatgridArm? {
        guard source.hasSteadyBeat, target.hasSteadyBeat,
              let srcBPM = source.bpm, srcBPM > 60, srcBPM < 200,
              let tgtBPM = target.bpm, tgtBPM > 60, tgtBPM < 200 else { return nil }

        let sRate = max(0.5, min(2.0, sourceRate))
        let tRate = max(0.5, min(2.0, targetRate))

        // Wall-clock beat period of each lane once rates are applied.
        let srcPeriod = (60.0 / srcBPM) / sRate
        let tgtPeriod = (60.0 / tgtBPM) / tRate
        // The two grids interlock only when their wall-clock periods match.
        let lockRatio = max(srcPeriod, tgtPeriod) / min(srcPeriod, tgtPeriod)
        let locked = lockRatio < 1.02
        let beatPeriod = (srcPeriod + tgtPeriod) / 2

        // Nearest source beat at or after the planner cue — the moment the
        // incoming downbeat must be rendered.
        let cueBeat = nearestBeatAtOrAfter(cueTime, beats: source.beats, fallbackPeriod: 60.0 / srcBPM)
        guard cueBeat.isFinite, cueBeat > sourceFileTime - 0.05 else { return nil }

        // Source file time advances at file rate; wall-clock time is divided
        // by the lane's playback rate (tempo stretch).
        let fileRunway = cueBeat - sourceFileTime
        let delay = fileRunway / sRate
        guard fileRunway > 0, delay.isFinite, delay > 0.02, delay <= maxArmDelay else { return nil }
        // The blend must not outrun the source file.
        guard cueBeat + blendDuration * 0.95 <= source.duration + 1.0 else { return nil }

        // Incoming entry beat: skip leading silence/dead air, then snap to the
        // target's own grid so its first audible beat is what lands on the
        // outgoing cue (starting a file at 0 would just roll silence up to
        // the first bar). Prefer the last of leading-silence end / first
        // detected beat / planner intro boundary, but never deep-entry.
        let candidates = [
            target.leadingSilence?.end ?? 0,
            target.firstBeat ?? 0,
            target.introEnd > 0.5 ? target.introEnd : 0
        ].filter { $0 > 0.05 }
        let musicalEntry = candidates.min() ?? 0
        let plannerEntry = min(max(musicalEntry, 0), maxEntrySeconds)
        let entryBeat = nearestBeatAtOrAfter(max(0, plannerEntry - 0.35),
                                             beats: target.beats,
                                             fallbackPeriod: 60.0 / tgtBPM)
        guard entryBeat.isFinite, entryBeat < min(target.duration, maxEntrySeconds + 4) else { return nil }

        let targetSR = targetFileSampleRate
        guard targetSR > 0, sourceFileSampleRate > 0 else { return nil }
        var entryFrame = AVAudioFramePosition((entryBeat * targetSR).rounded())
        entryFrame = max(0, min(entryFrame, max(0, targetFileLengthFrames - 2048)))

        return BeatgridArm(
            incomingStartFrame: entryFrame,
            incomingEntryTime: Double(entryFrame) / targetSR,
            cueTime: cueBeat,
            delay: delay,
            beatPeriod: beatPeriod,
            sourceRate: sRate,
            targetRate: tRate,
            locked: locked
        )
    }

    /// Closest detected beat at or after `time`; falls back to the analytic
    /// grid built from the first beat when no beat list exists yet.
    static func nearestBeatAtOrAfter(_ time: TimeInterval, beats: [Double], fallbackPeriod: Double) -> Double {
        let sorted = beats.sorted()
        if let match = sorted.first(where: { $0 >= time - 0.03 }) {
            return match
        }
        // Reconstruct the grid analytically from the last known beat so a
        // sparse beat list still yields a future downbeat.
        guard let last = sorted.last, fallbackPeriod > 0.2 else { return time }
        if last < time {
            let steps = ceil((time - last) / fallbackPeriod)
            return last + steps * fallbackPeriod
        }
        return time
    }

    /// Current sounding position of a scheduled player node, in *file time*
    /// of the track it is playing.
    ///
    /// AVAudioPlayerNode renders the decoded file 1:1 (the TimePitch unit
    /// downstream performs the stretching), so the node's own player time
    /// advances in file frames — independent of the lane playback rate.
    static func soundingFileTime(
        player: AVAudioPlayerNode,
        scheduledAtNodeSampleTime: AVAudioFramePosition,
        startFrame: AVAudioFramePosition,
        fileSampleRate: Double
    ) -> TimeInterval? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        let playedFrames = playerTime.sampleTime - scheduledAtNodeSampleTime
        guard playedFrames >= 0 else { return nil }
        let fileFrame = startFrame + playedFrames
        return Double(fileFrame) / fileSampleRate
    }
}
