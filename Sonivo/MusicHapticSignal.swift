import Foundation

/// Causal, bounded presentation queue. Decode-ahead is not an audible beat.
nonisolated struct MusicHapticTimeline {
    private var frames: [BeatWaveAudioFrame] = []
    private var lastStamp: TimeInterval?
    private var mediaMode: Bool?
    private(set) var dropped = 0

    mutating func reset() { frames.removeAll(keepingCapacity: true); lastStamp=nil; mediaMode=nil }
    mutating func push(_ frame: BeatWaveAudioFrame) {
        let media = frame.mediaTime != nil
        let stamp = frame.mediaTime ?? frame.capturedAt
        guard stamp.isFinite, stamp >= 0 else { return }
        if mediaMode != nil && mediaMode != media { reset() }
        mediaMode=media
        guard lastStamp == nil || stamp > lastStamp! else { return }
        lastStamp=stamp
        frames.append(frame)
        if frames.count > 1024 { dropped += frames.count-1024; frames.removeFirst(frames.count-1024) }
    }
    mutating func drain(at deadline: TimeInterval) -> [BeatWaveAudioFrame] {
        guard deadline.isFinite else { return [] }
        let count=frames.prefix { ($0.mediaTime ?? $0.capturedAt) <= deadline }.count
        let due=Array(frames.prefix(count)); frames.removeFirst(count)
        return due
    }
}

/// Persisted selection; kept with the pure signal model for deterministic fixtures.
nonisolated enum MusicHapticsMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case beat, full
    var id: String { rawValue }
    var title: String { self == .beat ? "Под бит" : "Полное звучание" }
    var detail: String {
        self == .beat
            ? "Короткие импульсы на подтверждённых ударах. Без постоянной вибрации."
            : "Непрерывная сила следует громкости; бас, удары и высокие частоты меняют характер вибрации."
    }
}

nonisolated struct MusicHapticOutput: Sendable {
    var kick: Float = 0
    var treble: Float = 0
    var body: Float = 0
    var bodySharpness: Float = 0.25
}

/// Single-actuator mix of measured PCM features; never synthesizes a beat grid.
nonisolated struct MusicHapticSignal {
    private var primed = false
    private var lastEventID: UInt64 = 0
    private var previousHigh: Float = 0
    private var highThreshold: Float = 0.02
    private var lastTreble: TimeInterval = -.infinity
    private var previousTime: TimeInterval?
    private var meanRMS: Float = 0.08

    mutating func reset() { self=MusicHapticSignal() }
    private func unit(_ value: Float) -> Float { value.isFinite ? max(0,min(1,value)) : 0 }
    mutating func process(_ frame: BeatWaveAudioFrame, ceiling: Float, automatic: Bool,
                          mode: MusicHapticsMode = .full) -> MusicHapticOutput {
        let time=frame.mediaTime ?? frame.capturedAt
        guard time.isFinite else { return MusicHapticOutput() }
        let dt=max(0.001,min(0.1,time-(previousTime ?? time-0.006)))
        previousTime=time
        let rms=unit(frame.rms), high=unit(frame.highs), limit=unit(ceiling)
        let flux=max(0,high-previousHigh)
        previousHigh=high
        let isNewKick=frame.kickEventID > lastEventID
        lastEventID=max(lastEventID,frame.kickEventID)
        if !primed { primed=true; return MusicHapticOutput() }
        let threshold=highThreshold
        highThreshold += (flux-highThreshold)*Float(1-exp(-dt/0.5))
        meanRMS += (rms-meanRMS)*Float(1-exp(-dt/1.5))
        guard rms > 0.003 else { return MusicHapticOutput() }
        let relative=max(0.8,min(1.2,rms/max(0.02,meanRMS)))
        // Perceptual compression opens the usable actuator range, while quiet PCM
        // remains weaker and digital silence stays off. No second confidence gain.
        let power=automatic ? min(1,pow(rms,0.35)*2.6*relative) : 1
        let strength=limit*power
        var output=MusicHapticOutput()
        if isNewKick && unit(frame.kickConfidence) > 0 { output.kick=strength }
        guard mode == .full else { return output }
        if flux > max(0.025,threshold*1.8), high > 0.04, time-lastTreble >= 0.055 {
            output.treble=strength; lastTreble=time
        }
        // Full mode represents ALL audible PCM, not only low-frequency content.
        // The chosen ceiling is applied once: never multiply three weak gains.
        output.body=strength
        let low=unit(frame.subBass)*0.6+unit(frame.bass)*0.4
        let bright=high/(low+unit(frame.mids)+high+0.01)
        output.bodySharpness=min(0.75,0.2+bright*0.55)
        return output
    }
}
