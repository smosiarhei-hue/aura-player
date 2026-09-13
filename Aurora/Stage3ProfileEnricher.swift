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
        guard sampleRate > 0 else { return [] }
        let startSec = min(15.0, max(0, Double(file.length) / sampleRate - 35.0))
        let startFrame = AVAudioFramePosition(max(0, startSec * sampleRate))
        file.framePosition = min(max(0, file.length - 1), startFrame)
        let durationFrames = AVAudioFramePosition(min(file.length - file.framePosition, AVAudioFramePosition(sampleRate * 30)))
        guard durationFrames > 4_096,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(durationFrames)) else {
            return []
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(durationFrames))
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let count = Int(buffer.frameLength)
        let stride = max(1, Int(sampleRate / 11_025))
        let effectiveRate = sampleRate / Double(stride)
        let blockSize = 1024
        var chroma = Array(repeating: Double(0), count: 12)
        for midi in 48...83 {
            try Task.checkCancellation()
            let frequency = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
            let omega = 2.0 * Double.pi * frequency / effectiveRate
            let coefficient = 2.0 * cos(omega)
            var noteEnergy = 0.0
            var blockStart = 0
            while blockStart + blockSize * stride <= count {
                var s0 = 0.0, s1 = 0.0, s2 = 0.0
                var i = blockStart
                let blockEnd = blockStart + blockSize * stride
                while i < blockEnd {
                    let sample = Double(channel[i])
                    s0 = sample + coefficient * s1 - s2
                    s2 = s1; s1 = s0
                    i += stride
                }
                let blockPower = max(0.0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)
                noteEnergy += blockPower
                blockStart += blockSize * stride
            }
            chroma[midi % 12] += log1p(noteEnergy / Double(max(1, count / (blockSize * stride))))
        }
        let peak = max(chroma.max() ?? 0, 1e-12)
        return chroma.map { Float($0 / peak) }
    }
}
