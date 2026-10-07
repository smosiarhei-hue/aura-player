import Foundation

/// Owner's prototype feature contract. Captured time is set in DSP, not when UI reads it.
nonisolated struct BeatWaveAudioFrame: Sendable {
    var capturedAt: TimeInterval = 0
    var subBass: Float = 0
    var bass: Float = 0
    var lowMids: Float = 0
    var mids: Float = 0
    var highs: Float = 0
    var rms: Float = 0
    var kickEnvelope: Float = 0
    var kickEventID: UInt64 = 0
    var kickConfidence: Float = 0
    var mediaTime: TimeInterval? = nil // Asset/sample clock, independent of polling/UI arrival.
    var bassFlux: Float? = nil // Positive per-bin spectral change, before display smoothing.
    var attackFlux: Float? = nil
}

/// Positive change of each raw FFT bin, never the already-smoothed UI spectrum.
nonisolated struct BeatWaveSpectralFlux {
    private var previous: [Float] = []
    private var previousRate: Double = 0
    mutating func reset() { previous.removeAll(keepingCapacity: true); previousRate=0 }
    mutating func process(magnitudes: [Float],sampleRate: Double) -> (bass: Float,attack: Float) {
        guard sampleRate.isFinite,sampleRate>0,magnitudes.count>1 else { return (0,0) }
        if previous.count != magnitudes.count || abs(previousRate-sampleRate)>1 {
            previous=[Float](repeating: 0,count: magnitudes.count); previousRate=sampleRate
        }
        let size=Float(magnitudes.count*2)
        var low: Float=0,attack: Float=0,lowCount: Float=0,attackCount: Float=0
        for bin in 1..<magnitudes.count {
            let raw=magnitudes[bin].isFinite ? max(0,magnitudes[bin]) : 0
            let value=log1p(raw/size*32)
            let rise=max(0,value-previous[bin])
            let hz=Float(bin)*Float(sampleRate)/size
            if hz>=30 && hz<=180 { low+=rise; lowCount+=1 }
            if hz>180 && hz<=2000 { attack+=rise; attackCount+=1 }
            previous[bin]=value
        }
        return (min(1,low/max(1,lowCount)*2.5),min(1,attack/max(1,attackCount)*2.5))
    }
}

nonisolated struct BeatWaveKickDetector {
    private var history: [(time: TimeInterval,flux: Float)] = []
    private var previousBass: Float = 0
    private var previousRMS: Float = 0
    private var lastKick: TimeInterval = -.infinity
    private var previousTime: TimeInterval?
    private(set) var eventID: UInt64 = 0
    private(set) var envelope: Float = 0
    private(set) var confidence: Float = 0

    mutating func process(_ frame: BeatWaveAudioFrame) {
        let dt = max(0, min(0.1, frame.capturedAt - (previousTime ?? frame.capturedAt)))
        previousTime = frame.capturedAt
        envelope *= exp(-Float(dt) / 0.12)
        if envelope < 0.001 { envelope = 0 }
        let bass = unit(frame.subBass) * 0.65 + unit(frame.bass) * 0.35
        let flux: Float
        if let measured=frame.bassFlux {
            flux=unit(measured)*0.85+unit(frame.attackFlux ?? 0)*0.15
        } else {
            flux=max(0,bass-previousBass)*0.75+max(0,unit(frame.rms)-previousRMS)*0.25
        }
        history.removeAll { frame.capturedAt-$0.time>0.8 }
        // Threshold uses prior history: the onset must not raise its own threshold.
        let mean = history.isEmpty ? 0 : history.reduce(Float(0)) { $0+$1.flux } / Float(history.count)
        let variance = history.isEmpty ? 0 : history.reduce(Float(0)) { $0 + pow($1.flux-mean,2) } / Float(history.count)
        let threshold = max(frame.bassFlux==nil ? 0.025 : 0.012, mean + 1.35 * sqrt(variance))
        let suppressed = (frame.highs > bass * 2.8 && bass < 0.22) || (frame.mids > bass * 2.2 && bass < 0.15)
        if !suppressed && unit(frame.rms)>0.008 && frame.capturedAt-lastKick >= 0.160 && flux > threshold && bass > 0.10 {
            eventID &+= 1
            lastKick = frame.capturedAt
            envelope = 1
            confidence = min(1, 0.55 + (flux-threshold)/max(0.05,threshold)*0.45)
        }
        history.append((frame.capturedAt,flux))
        if history.count > 256 { history.removeFirst() }
        previousBass = bass
        previousRMS = unit(frame.rms)
    }

    mutating func reset() {
        // IDs remain monotonic; seek/track resets cannot make the UI miss all future events.
        history.removeAll(keepingCapacity: true)
        previousBass = 0; previousRMS = 0; previousTime = nil
        lastKick = -.infinity; envelope = 0; confidence = 0
    }
    private func unit(_ value: Float) -> Float { value.isFinite ? max(0,min(1,value)) : 0 }
}

/// Responsive audio-driven flow and one-shot geometric impulse; no metronome or guessed tempo.
nonisolated enum BeatWaveBandEnergy {
    /// Values are already means of FFT bins. Weight by populated bin counts, not empty log slots.
    static func mean(values: [Float], counts: [Int], range: Range<Int>) -> Float {
        var sum: Float = 0
        var populatedBins = 0
        for i in range where i>=0 && i<values.count && i<counts.count && counts[i]>0 {
            guard values[i].isFinite else { continue }
            let count=counts[i]
            sum += max(0,min(1,values[i])) * Float(count)
            populatedBins += count
        }
        return populatedBins>0 ? max(0,min(1,sum/Float(populatedBins))) : 0
    }
}

/// Slow coherent flow. Bass controls deformation; only a measured onset excites the spring.
nonisolated struct MusicWaveMotion {
    private(set) var phase: Double = 0
    private(set) var energy: Float = 0
    private(set) var lowEnergy: Float = 0
    private(set) var impact: Float = 0
    private(set) var detail: Float = 0
    private(set) var speed: Float = 0
    private(set) var springPosition: Float = 0
    private(set) var springVelocity: Float = 0
    private(set) var lastKickEventID: UInt64 = 0

    mutating func consume(_ id: UInt64) { lastKickEventID = max(lastKickEventID,id) }

    @discardableResult
    mutating func advance(delta: Float, frame: BeatWaveAudioFrame, hasFreshAudio: Bool) -> Bool {
        let dt = delta.isFinite ? max(0, min(0.1, delta)) : 0
        guard dt > 0 else { return false }
        func unit(_ value: Float) -> Float { value.isFinite ? max(0,min(1,value)) : 0 }
        let bass = unit((unit(frame.subBass)*0.95*0.95 + unit(frame.bass))*0.55)
        let mids = unit(unit(frame.mids)*0.6 + unit(frame.lowMids)*0.4)
        // Log FFT levels include quiet noise. Gate every musical channel by real PCM energy.
        let signal = hasFreshAudio ? unit((unit(frame.rms)-0.008)/0.06) : 0
        let targetLow = bass*signal
        let targetEnergy = unit((bass*0.55 + mids*0.25 + unit(frame.rms)*0.20)*signal)
        lowEnergy += (targetLow-lowEnergy)*(1-exp(-dt/(targetLow>lowEnergy ? 0.045 : 0.35)))
        let newKick = hasFreshAudio && signal>0 && frame.kickEventID > lastKickEventID
        let kickStrength = newKick ? unit(frame.kickConfidence) : 0
        let targetImpact = hasFreshAudio ? max(unit(frame.kickEnvelope),kickStrength)*signal : 0
        let targetDetail = unit((unit(frame.highs)*0.55+unit(frame.mids)*0.45)*signal)
        energy += (targetEnergy-energy)*(1-exp(-dt/(targetEnergy>energy ? 0.12 : (hasFreshAudio ? 0.45 : 0.20))))
        impact += (targetImpact-impact)*(1-exp(-dt/(targetImpact>impact ? 0.025 : (hasFreshAudio ? 0.30 : 0.20))))
        detail += (targetDetail-detail)*(1-exp(-dt/(targetDetail>detail ? 0.08 : 0.26)))
        // One event, one soft impulse. Critically damped: no bouncing/secondary "ticks".
        if newKick { impact=max(impact,kickStrength); springVelocity += 0.75*kickStrength }
        consume(frame.kickEventID)
        // m=1, k=64, c=16. Exact critical solution is stable even after a frame hitch.
        let decay: Float = 8
        let x = springPosition, v = springVelocity
        let coefficient = v+decay*x
        let attenuation = exp(-decay*dt)
        springPosition = (x+coefficient*dt)*attenuation
        springVelocity = (v-decay*coefficient*dt)*attenuation
        if abs(springPosition)<0.0005 && abs(springVelocity)<0.001 { springPosition=0; springVelocity=0 }
        // No baseline clock: silence stops flow. Loudness changes speed gently, not beat flashes.
        let targetSpeed: Float = hasFreshAudio ? min(0.18,energy*0.16+lowEnergy*0.025) : 0
        speed += (targetSpeed-speed)*(1-exp(-dt/(targetSpeed>speed ? 0.45 : 0.60)))
        if !hasFreshAudio || signal==0 {
            if lowEnergy<0.008 { lowEnergy=0 }
            if energy<0.008 { energy=0 }; if impact<0.008 { impact=0 }; if speed<0.008 { speed=0 }
        }
        phase += Double(dt * speed) // No arbitrary phase wrap: shader frequencies are not commensurate.
        return newKick
    }
    mutating func settle() {
        energy=0; lowEnergy=0; impact=0; detail=0; speed=0; springPosition=0; springVelocity=0
    }
}

/// A bounded, causal presentation queue. It never returns a future audio feature.
nonisolated struct BeatWavePresentation {
    private var queue: [BeatWaveAudioFrame] = []
    private var latestCapture: TimeInterval = -.infinity
    private var presented = BeatWaveAudioFrame()
    mutating func push(_ frame: BeatWaveAudioFrame) {
        guard frame.capturedAt.isFinite,frame.capturedAt > latestCapture else { return }
        if let time=frame.mediaTime,!time.isFinite { return }
        latestCapture = frame.capturedAt
        queue.append(frame)
        if queue.count>256 { queue.removeFirst(queue.count-256) }
    }
    mutating func sample(now: TimeInterval, estimatedOutputDelay: TimeInterval) -> BeatWaveAudioFrame {
        let cutoff = now-max(0,min(0.5,estimatedOutputDelay))
        while let first=queue.first, first.capturedAt<=cutoff { presented=queue.removeFirst() }
        return presented
    }
    mutating func sampleMedia(at mediaTime: TimeInterval) -> BeatWaveAudioFrame? {
        guard mediaTime.isFinite else { return nil }
        while let first=queue.first {
            guard let sampleTime=first.mediaTime else { queue.removeFirst(); continue }
            guard sampleTime<=mediaTime else { break }
            presented=queue.removeFirst()
        }
        guard let sampleTime=presented.mediaTime,sampleTime<=mediaTime else { return nil }
        return presented
    }
    mutating func reset() { queue.removeAll(keepingCapacity: true); latestCapture = -.infinity; presented=BeatWaveAudioFrame() }
}
