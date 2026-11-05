// Path: Packages/AutoMixV2/Sources/AudioEngineCore/StemSeparator.swift
//
// Offline Automix stem separation for mashup bake windows.
// Neural HTDemucs (7.8 s, 50% overlap-add) lives in StemSplit/ and stays
// passthrough until HTDemucs.mlmodelc is in the app bundle. This baker still
// uses the hybrid carve below. AUSoundIsolation stays off.

@preconcurrency import AVFAudio
import AudioToolbox
import Foundation

public enum StemSeparationBackend: String, Sendable, Equatable {
    /// System AUSoundIsolation neural path (device / Apple Silicon).
    case soundIsolation = "soundIsolation"
    /// Mid/side cancel + residual vocal (no ML weights).
    case hybridSpectral = "hybridSpectral"
}

/// Offline stem DSP used by `MidSideStemBaker` (whole mashup window).
public enum StemSeparator {
    /// Last backend that successfully carved a stem in this process.
    nonisolated(unsafe) public static var lastBackend: StemSeparationBackend = .hybridSpectral

    /// AUSoundIsolation ruins instrumental body in field mixes (1055+).
    /// Keep OFF until Automix Lab proves a better neural bake — then flip on.
    nonisolated(unsafe) public static var useSoundIsolation: Bool = false

    public struct State: Sendable {
        public var bass1: Float = 0
        public var bass2: Float = 0
        public var body: Float = 0
        public var lead: Float = 0
        public var pres: Float = 0
        public var smoothed: Float = 0
        public init() {}
    }

    /// Separate one stereo window in place (`left`/`right` length == `frames`).
    public static func separateWindow(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int,
        mode: MidSideStemMode,
        amount: Float,
        sampleRate: Double
    ) {
        guard frames > 0 else { return }
        let a = min(1, max(0, amount))
        switch mode {
        case .dry:
            lastBackend = .hybridSpectral
            return
        case .instrumental:
            // Lab-first: Mid/Side bed carve (not AU) until neural quality is proven.
            if useSoundIsolation,
               renderInstrumentalPreferringAU(
                left: left, right: right, frames: frames,
                amount: a, sampleRate: sampleRate
               ) {
                return
            }
            var state = State()
            renderHybridInstrumental(
                left: left, right: right, frames: frames,
                amount: a, sampleRate: sampleRate, state: &state
            )
            lastBackend = .hybridSpectral
        case .vocal:
            var dryL = [Float](repeating: 0, count: frames)
            var dryR = [Float](repeating: 0, count: frames)
            dryL.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: left, count: frames) }
            dryR.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: right, count: frames) }

            let usedAU = useSoundIsolation && renderInstrumentalPreferringAU(
                left: left, right: right, frames: frames,
                amount: a, sampleRate: sampleRate
            )
            if !usedAU {
                left.update(from: dryL, count: frames)
                right.update(from: dryR, count: frames)
                var state = State()
                renderHybridInstrumental(
                    left: left, right: right, frames: frames,
                    amount: a, sampleRate: sampleRate, state: &state
                )
                lastBackend = .hybridSpectral
            }
            // Residual = dry − instrumental. Keep near-unity gain (field 1055
            // ~2× makeup + softClip made A vocal fizzy/cheap under B bed).
            let gain: Float = 0.92 + 0.18 * a // ≈1.0–1.10 at Automix amount
            // Mild stereo collapse only — heavy mid-sum turned bleed into mud.
            let sideKeep: Float = 1 - 0.40 * a
            // One-pole HPF ~150 Hz to strip kick/mud from residual lead.
            let alpha = Float(exp(-2.0 * Double.pi * 150.0 / max(1.0, sampleRate)))
            var prevXL: Float = 0
            var prevXR: Float = 0
            var prevYL: Float = 0
            var prevYR: Float = 0
            var peak: Float = 1e-6
            for i in 0..<frames {
                let xL = (dryL[i] - left[i]) * gain
                let xR = (dryR[i] - right[i]) * gain
                let yL = alpha * (prevYL + xL - prevXL)
                let yR = alpha * (prevYR + xR - prevXR)
                prevXL = xL
                prevXR = xR
                prevYL = yL
                prevYR = yR
                let mid = (yL + yR) * 0.5
                let side = (yL - yR) * 0.5 * sideKeep
                let oL = mid + side
                let oR = mid - side
                peak = max(peak, max(abs(oL), abs(oR)))
                left[i] = oL
                right[i] = oR
            }
            // Peak-normalize only when residual would clip; skip softClip distortion.
            if peak > 0.95 {
                let scale = 0.95 / peak
                for i in 0..<frames {
                    left[i] *= scale
                    right[i] *= scale
                }
            }
        }
    }

    /// Try AU on a scratch buffer so a partial render never corrupts the dry window.
    @discardableResult
    private static func renderInstrumentalPreferringAU(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int,
        amount: Float,
        sampleRate: Double
    ) -> Bool {
        var tryL = [Float](repeating: 0, count: frames)
        var tryR = [Float](repeating: 0, count: frames)
        tryL.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: left, count: frames) }
        tryR.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: right, count: frames) }
        let ok = tryL.withUnsafeMutableBufferPointer { lBuf in
            tryR.withUnsafeMutableBufferPointer { rBuf in
                SoundIsolationOffline.renderInstrumentalInPlace(
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!,
                    frames: frames,
                    sampleRate: sampleRate,
                    wetPercent: Double(amount) * 100
                )
            }
        }
        guard ok else { return false }
        left.update(from: tryL, count: frames)
        right.update(from: tryR, count: frames)
        lastBackend = .soundIsolation
        return true
    }

    /// Lab-style Mid/Side **bed** carve (`vocalInstrumental.ts` instrumental/bed):
    /// keep sub + body + sides; soft-tuck formant/presence. Never nuclear mid-mute.
    public static func renderHybridInstrumental(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int,
        amount: Float,
        sampleRate: Double = 44_100,
        state: inout State
    ) {
        guard frames > 0 else { return }
        let target = min(1, max(0, amount))
        let ramp: Float = 0.015
        let sr = max(1.0, sampleRate)
        let lpA = Float(1 - exp(-2.0 * Double.pi * 150.0 / sr))
        let bodyA = Float(1 - exp(-2.0 * Double.pi * 800.0 / sr))
        let leadA = Float(1 - exp(-2.0 * Double.pi * 1600.0 / sr))
        let presA = Float(1 - exp(-2.0 * Double.pi * 2800.0 / sr))
        // Soft karaoke tuck — matches lab bed cuts (not leadKill).
        let bodyCut: Float = 0.22
        let formantCut: Float = 0.55
        let presCut: Float = 0.85
        let sideBoostAmt: Float = 0.12
        for i in 0..<frames {
            state.smoothed += (target - state.smoothed) * ramp
            let a = state.smoothed
            let l = left[i]
            let r = right[i]
            let mid = (l + r) * 0.5
            let side = (l - r) * 0.5
            state.bass1 += lpA * (mid - state.bass1)
            let midHi = mid - state.bass1
            state.body += bodyA * (midHi - state.body)
            let midRest = midHi - state.body
            state.lead += leadA * (midRest - state.lead)
            state.pres += presA * (midRest - state.lead - state.pres)
            let midKeep =
                state.bass1 * (1 + 0.06 * a) +
                state.body * (1 - bodyCut * a) +
                state.lead * (1 - formantCut * a) +
                state.pres * (1 - presCut * a)
            let sideKeep = side * (1 + sideBoostAmt * a)
            // Wet/dry so soft amounts don't thin the groove.
            let wetL = midKeep + sideKeep
            let wetR = midKeep - sideKeep
            left[i] = softClip(l + (wetL - l) * a)
            right[i] = softClip(r + (wetR - r) * a)
        }
    }

    public static func softClip(_ x: Float) -> Float {
        let lim: Float = 0.98
        if x > lim { return lim + (x - lim) / (1 + (x - lim) * 4) }
        if x < -lim { return -lim + (x + lim) / (1 + (-x - lim) * 4) }
        return x
    }
}

// MARK: - Apple AUSoundIsolation (optional system AU)

enum SoundIsolationOffline {
    private static let wetDryParam: AUParameterAddress = 0

    static func isAvailable() -> Bool {
        findDescription() != nil
    }

    static func findDescription() -> AudioComponentDescription? {
        var search = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        var current: AudioComponent?
        while true {
            current = AudioComponentFindNext(current, &search)
            guard let current else { return nil }
            var name: Unmanaged<CFString>?
            guard AudioComponentCopyName(current, &name) == noErr,
                  let cf = name?.takeRetainedValue() as String? else { continue }
            let lower = cf.lowercased()
            if lower.contains("sound isolation") || lower.contains("ausoundisolation") {
                var desc = AudioComponentDescription()
                guard AudioComponentGetDescription(current, &desc) == noErr else { continue }
                return desc
            }
        }
    }

    /// Attenuate center vocals for the whole window. False → caller uses hybrid.
    static func renderInstrumentalInPlace(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int,
        sampleRate: Double,
        wetPercent: Double
    ) -> Bool {
        guard frames > 0, frames <= 2_000_000, sampleRate > 0,
              let desc = findDescription() else { return false }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else { return false }

        do {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let effect = AVAudioUnitEffect(audioComponentDescription: desc)
            engine.attach(player)
            engine.attach(effect)
            engine.connect(player, to: effect, format: format)
            engine.connect(effect, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 1

            let wet = AUValue(max(0, min(100, wetPercent)))
            if let tree = effect.auAudioUnit.parameterTree {
                tree.parameter(withAddress: wetDryParam)?.value = wet
                // Undocumented Music Sing tuning flags (safe no-ops if absent).
                tree.parameter(withAddress: 95782)?.value = 1
                tree.parameter(withAddress: 95783)?.value = 1
            }

            let maxFrames: AVAudioFrameCount = 4_096
            try engine.enableManualRenderingMode(
                .offline,
                format: format,
                maximumFrameCount: maxFrames
            )
            try engine.start()

            guard let srcBuf = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ),
                let srcL = srcBuf.floatChannelData?[0],
                let srcR = srcBuf.floatChannelData?[1],
                let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames),
                let outL = outBuf.floatChannelData?[0],
                let outR = outBuf.floatChannelData?[1]
            else {
                engine.stop()
                return false
            }

            srcBuf.frameLength = AVAudioFrameCount(frames)
            srcL.update(from: left, count: frames)
            srcR.update(from: right, count: frames)
            player.scheduleBuffer(srcBuf, at: nil, options: [])
            player.play()

            var written = 0
            while written < frames {
                let want = min(frames - written, Int(maxFrames))
                outBuf.frameLength = AVAudioFrameCount(want)
                let status = try engine.renderOffline(AVAudioFrameCount(want), to: outBuf)
                guard status == .success else {
                    engine.stop()
                    return false
                }
                let got = Int(outBuf.frameLength)
                guard got > 0 else { break }
                left.advanced(by: written).update(from: outL, count: got)
                right.advanced(by: written).update(from: outR, count: got)
                written += got
            }

            player.stop()
            engine.stop()
            // Require a complete window — partial AU output must not ship.
            return written == frames
        } catch {
            return false
        }
    }
}
