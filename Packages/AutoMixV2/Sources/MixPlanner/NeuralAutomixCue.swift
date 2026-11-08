// Path: Packages/AutoMixV2/Sources/MixPlanner/NeuralAutomixCue.swift
//
// Fuses energy/vocal curves + timed lyrics into a bar-snapped mixOut / mixIn
// while the track is already playing. Port of tools/automix-lab neuralAutomix.ts.

import Foundation
import MixModels

public struct NeuralCue: Sendable, Equatable {
    public let mixOutSec: Double
    public let mixInSec: Double
    public let confidence: Double
    public let reason: String
    public let source: Source

    public enum Source: String, Sendable, Equatable {
        case energy
        case lyrics
        case fused
    }
}

public enum NeuralCueRole: Sendable {
    case outgoing
    case incoming
    case both
}

public enum NeuralAutomixCue {
    public static func pick(
        profile: TrackProfile,
        transcript: AutomixTranscript?
    ) -> NeuralCue {
        let duration = profile.durationSec
        let energyCue = profile.mixOutSec
        let tx = transcript.map {
            AutomixTranscriptCue.cue(from: $0, durationSec: duration, minTailSec: 24)
        }
        let blended = AutomixTranscriptCue.blendMixOut(
            energyMixOut: energyCue,
            transcriptCue: tx?.mixOutSec,
            durationSec: duration,
            minTailSec: 24,
            transcriptConfidence: tx?.confidence ?? 0.7
        )

        var mixOut = blended.mixOut
        var source: NeuralCue.Source = blended.usedTranscript ? .fused : .energy
        var confidence = blended.usedTranscript
            ? max(0.72, tx?.confidence ?? 0.78)
            : 0.55

        let energy = profile.energyCurve
        let vocal = profile.vocalPresence
        // TrackAnalyzer currently stores one energy sample per second. Derive
        // the spacing from the profile instead of assuming 250 ms bins.
        let hop = duration.isFinite && duration > 0 && !energy.isEmpty
            ? duration / Double(energy.count) : 1.0
        let lyricsLock = blended.usedTranscript && (tx?.confidence ?? 0) >= 0.75

        if energy.count > 16, vocal.count == energy.count,
           mixOut.isFinite, hop.isFinite, hop > 0,
           mixOut >= 0, mixOut / hop < Double(energy.count) {
            let center = Int(floor(mixOut / hop))
            func bins(_ seconds: Double) -> Int {
                Int(min(Double(energy.count), max(1, (seconds / hop).rounded(.up))))
            }
            let radius = bins(lyricsLock ? 4.0 : 8.0)
            let forward = bins(lyricsLock ? 6.0 : 12.0)
            let vocalLookAhead = bins(1.0)
            let energyLookAhead = bins(6.0)
            let localLookBehind = bins(3.0)
            let lo = min(energy.count - 2, max(0, center - radius))
            let hi = min(energy.count - 1, max(lo, center + forward))
            var best = center
            var bestScore = -1.0
            for i in lo..<hi {
                let v0 = Double(vocal[i])
                let v1 = Double(vocal[min(vocal.count - 1, i + vocalLookAhead)])
                let e0 = Double(energy[i])
                let drop = max(0, v0 - v1)
                let bed = e0 * (1 - v1)
                var ahead = 0.0
                for k in 0..<energyLookAhead {
                    ahead += Double(energy[min(energy.count - 1, i + k)])
                }
                ahead /= Double(energyLookAhead)
                var localMax = e0
                for k in -localLookBehind...energyLookAhead {
                    let idx = max(0, min(energy.count - 1, i + k))
                    localMax = max(localMax, Double(energy[idx]))
                }
                let hole = ahead < max(0.32, localMax * 0.58) ? 4.5 : 0.0
                let nearTx: Double
                if let txOut = tx?.mixOutSec {
                    nearTx = 1 - min(1, abs(Double(i) * hop - txOut) / (lyricsLock ? 4 : 8))
                } else {
                    nearTx = 0.4
                }
                let txWeight = lyricsLock ? 2.4 : 1.4
                let score = drop * 2.2 + bed * 1.1 + ahead * 1.8 + nearTx * txWeight - hole
                if score > bestScore {
                    bestScore = score
                    best = i
                }
            }
            if bestScore > 0.35 {
                mixOut = Double(best) * hop
                confidence = min(0.95, max(confidence, 0.5 + bestScore / 6))
                if blended.usedTranscript { source = .fused }
            }
        } else if blended.usedTranscript {
            source = .lyrics
            confidence = max(confidence, 0.82)
        }

        mixOut = clampOut(mixOut, duration: duration)
        // Snap only to a measured, sufficiently trusted downbeat, never to a
        // grid invented from time zero or a made-up 120 BPM.
        if profile.confidence.downbeats >= 0.70,
           let beat = profile.downbeatsSec.filter({ $0.isFinite }).min(by: { abs($0 - mixOut) < abs($1 - mixOut) }),
           profile.bpm > 30,
           abs(beat - mixOut) <= 120.0 / Double(profile.bpm) {
            mixOut = clampOut(beat, duration: duration)
        }

        let mixIn: Double
        if let txIn = tx?.mixInSec, txIn.isFinite {
            mixIn = max(0, min(duration * 0.28, txIn))
        } else {
            mixIn = profile.mixInSec
        }

        let sourceLabel: String = {
            switch source {
            case .lyrics: return "LRC/Whisper phrase"
            case .fused: return "energy×lyrics"
            case .energy: return "energy/vocal"
            }
        }()
        var parts = [
            sourceLabel,
            "@\(String(format: "%.1f", mixOut))s",
            "conf \(Int(confidence * 100))%"
        ]
        if blended.usedTranscript, let reason = tx?.reason {
            parts.append(reason)
        }

        return NeuralCue(
            mixOutSec: mixOut,
            mixInSec: mixIn,
            confidence: confidence,
            reason: parts.joined(separator: " · "),
            source: source
        )
    }

    /// Apply neural cue onto a profile (immutable).
    public static func applying(
        to profile: TrackProfile,
        transcript: AutomixTranscript?,
        role: NeuralCueRole = .both
    ) -> TrackProfile {
        let cue = pick(profile: profile, transcript: transcript)
        switch role {
        case .outgoing:
            return profile.replacingCues(mixInSec: profile.mixInSec, mixOutSec: cue.mixOutSec)
        case .incoming:
            return profile.replacingCues(mixInSec: cue.mixInSec, mixOutSec: profile.mixOutSec)
        case .both:
            return profile.replacingCues(mixInSec: cue.mixInSec, mixOutSec: cue.mixOutSec)
        }
    }

    private static func clampOut(_ sec: Double, duration: Double, minTail: Double = 24) -> Double {
        let window = AutomixTranscriptCue.outroWindow(durationSec: duration, minTailSec: minTail)
        return min(window.latest, max(window.earliest, sec))
    }
}

public extension TrackProfile {
    func replacingCues(mixInSec: Double, mixOutSec: Double) -> TrackProfile {
        TrackProfile(
            profileVersion: profileVersion,
            trackID: trackID,
            durationSec: durationSec,
            sourceSampleRate: sourceSampleRate,
            sourceBitrateKbps: sourceBitrateKbps,
            bpm: bpm,
            beatsSec: beatsSec,
            downbeatsSec: downbeatsSec,
            phraseStartsSec: phraseStartsSec,
            tempoStability: tempoStability,
            camelotKey: camelotKey,
            integratedLUFS: integratedLUFS,
            loudnessCurveLUFS: loudnessCurveLUFS,
            energyCurve: energyCurve,
            hasFadeOut: hasFadeOut,
            endsInSilence: endsInSilence,
            vocalPresence: vocalPresence,
            segments: segments,
            mixInSec: mixInSec,
            mixOutSec: mixOutSec,
            mixable: mixable,
            confidence: confidence
        )
    }
}
