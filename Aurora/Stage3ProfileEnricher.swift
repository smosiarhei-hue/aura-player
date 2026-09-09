@preconcurrency import AVFAudio
import Foundation
import MixModels
import TrackAnalysis

nonisolated enum Stage3ProfileEnricher {
    static func enrich(_ profile: TrackProfile, fileURL: URL) async -> TrackProfile {
        let key = await Task.detached(priority: .utility) {
            (try? chroma(fileURL: fileURL)).map(HarmonicKeyDetector.estimate)
        }.value ?? nil
        guard let key else { return profile }
        return TrackProfile(profileVersion: profile.profileVersion,
                            trackID: profile.trackID,
                            durationSec: profile.durationSec,
                            sourceSampleRate: profile.sourceSampleRate,
                            sourceBitrateKbps: profile.sourceBitrateKbps,
                            bpm: profile.bpm,
                            beatsSec: profile.beatsSec,
                            downbeatsSec: profile.downbeatsSec,
                            phraseStartsSec: profile.phraseStartsSec,
                            tempoStability: profile.tempoStability,
                            camelotKey: key.camelot,
                            integratedLUFS: profile.integratedLUFS,
                            loudnessCurveLUFS: profile.loudnessCurveLUFS,
                            energyCurve: profile.energyCurve,
                            hasFadeOut: profile.hasFadeOut,
                            endsInSilence: profile.endsInSilence,
                            vocalPresence: profile.vocalPresence,
                            segments: profile.segments,
                            mixInSec: profile.mixInSec,
                            mixOutSec: profile.mixOutSec,
                            mixable: profile.mixable,
                            confidence: Confidence(bpm: profile.confidence.bpm,
                                                   downbeats: profile.confidence.downbeats,
                                                   key: key.confidence))
    }

    private static func chroma(fileURL: URL) throws -> [Float] {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: fileURL)
        let sampleRate = file.processingFormat.sampleRate
        let maximum = min(file.length, AVAudioFramePosition(sampleRate * 90))
        guard maximum > 4_096,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(maximum)) else {
            return []
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(maximum))
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let count = Int(buffer.frameLength)
        let stride = max(1, Int(sampleRate / 11_025))
        let effectiveRate = sampleRate / Double(stride)
        var chroma = Array(repeating: Double(0), count: 12)
        for midi in 36...95 {
            try Task.checkCancellation()
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            let omega = 2 * Double.pi * frequency / effectiveRate
            let coefficient = 2 * cos(omega)
            var s0 = 0.0, s1 = 0.0, s2 = 0.0
            var index = 0
            while index < count {
                s0 = Double(channel[index]) + coefficient * s1 - s2
                s2 = s1; s1 = s0; index += stride
            }
            let power = max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)
            chroma[midi % 12] += log1p(power)
        }
        let peak = max(chroma.max() ?? 0, 1e-12)
        return chroma.map { Float($0 / peak) }
    }
}
