@preconcurrency import AVFAudio
import AudioEngineCore
import Foundation
import MixModels

@MainActor
final class DualDeckAudioEngine {
    static let preferredSampleRate = 48_000.0
    static let preferredIOBufferDuration = 0.005

    private final class Slot: @unchecked Sendable {
        let deck: Deck
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let mixer = AVAudioMixerNode()
        var file: AVAudioFile?
        var url: URL?
        var start = 0.0
        var duration = 0.0
        var rate: Float = 1
        var prepared = false
        var playing = false
        var ended = false
        init(_ deck: Deck) { self.deck = deck }
    }

    private let graph = AVAudioEngine()
    private let a = Slot(.a)
    private let b = Slot(.b)

    init() throws {
        for slot in [a, b] {
            graph.attach(slot.player); graph.attach(slot.timePitch); graph.attach(slot.mixer)
            graph.connect(slot.player, to: slot.timePitch, format: nil)
            graph.connect(slot.timePitch, to: slot.mixer, format: nil)
            graph.connect(slot.mixer, to: graph.mainMixerNode, format: nil)
            slot.timePitch.pitch = 0; slot.timePitch.rate = 1; slot.timePitch.overlap = 8
        }
        a.mixer.outputVolume = 1; b.mixer.outputVolume = 0; graph.prepare()
    }

    func prepare(_ deck: Deck, fileURL: URL, startTimeSeconds: Double = 0) async throws {
        try Task.checkCancellation()
        let s = slot(deck); s.player.stop(); s.player.reset()
        let file = try AVAudioFile(forReading: fileURL)
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { throw AudioEngineCoreError.unsupportedOutputFormat }
        let duration = Double(file.length) / sr
        let start = min(max(0, startTimeSeconds), max(0, duration - 1 / sr))
        let frame = AVAudioFramePosition(start * sr)
        let count = AVAudioFrameCount(min(Int64(UInt32.max), max(1, file.length - frame)))
        s.file = file; s.url = fileURL; s.start = start; s.duration = duration
        s.prepared = true; s.playing = false; s.ended = false
        s.player.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil) { [weak s] in
            Task { @MainActor in s?.playing = false; s?.ended = true }
        }
    }

    func play(_ deck: Deck) async throws {
        let s = slot(deck); guard s.prepared else { throw AudioEngineCoreError.deckNotPrepared(deck) }
        if !graph.isRunning { try graph.start() }
        s.player.play(); s.playing = true
    }
    func pause(_ deck: Deck) async { slot(deck).player.pause(); slot(deck).playing = false }
    func resume(_ deck: Deck) async throws { try await play(deck) }
    func stop(_ deck: Deck) async {
        let s = slot(deck); s.player.stop(); s.player.reset(); s.file = nil; s.url = nil
        s.start = 0; s.duration = 0; s.rate = 1; s.timePitch.rate = 1
        s.prepared = false; s.playing = false; s.ended = false
    }
    func stopEngine() async { await stop(.a); await stop(.b); graph.stop() }
    func setGain(_ gain: Float, for deck: Deck) async {
        slot(deck).mixer.outputVolume = min(1, max(0, gain.isFinite ? gain : 0))
    }
    func setRate(_ rate: Float, for deck: Deck) async {
        let value = min(1.08, max(0.92, rate.isFinite ? rate : 1))
        slot(deck).rate = value; slot(deck).timePitch.rate = value
    }
    func skip(from current: Deck, to next: Deck) async throws {
        try await play(next); await setGain(1, for: next); await stop(current)
    }
    func crossfade(from outgoing: Deck, to incoming: Deck, durationSeconds: Double) async throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw AudioEngineCoreError.conversionFailed("Invalid transition duration")
        }
        try await play(incoming)
        let started = ContinuousClock().now
        while true {
            try Task.checkCancellation()
            let elapsed = started.duration(to: ContinuousClock().now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let p = min(1, max(0, seconds / durationSeconds))
            slot(outgoing).mixer.outputVolume = Float(cos(p * .pi / 2))
            slot(incoming).mixer.outputVolume = Float(sin(p * .pi / 2))
            if p >= 1 { break }
            try await ContinuousClock().sleep(for: .milliseconds(5))
        }
        await stop(outgoing); await setGain(1, for: incoming)
    }
    func snapshot() async -> AudioEngineSnapshot {
        let f = graph.outputNode.outputFormat(forBus: 0)
        return AudioEngineSnapshot(isRunning: graph.isRunning, sampleRate: f.sampleRate,
                                   channels: f.channelCount, deckA: snapshot(a), deckB: snapshot(b))
    }
    private func snapshot(_ s: Slot) -> DeckPlaybackSnapshot {
        let played: Double
        if let r = s.player.lastRenderTime, let t = s.player.playerTime(forNodeTime: r), t.sampleRate > 0 {
            played = Double(t.sampleTime) / t.sampleRate * Double(s.rate)
        } else { played = 0 }
        let position = s.ended ? s.duration : min(s.duration, s.start + max(0, played))
        return DeckPlaybackSnapshot(deck: s.deck, fileURL: s.url, isPrepared: s.prepared,
                                    isPlaying: s.playing, gain: s.mixer.outputVolume,
                                    queuedChunks: s.prepared && !s.ended ? 1 : 0,
                                    reachedEndOfFile: s.ended, positionSeconds: position,
                                    durationSeconds: s.prepared ? s.duration : nil)
    }
    private func slot(_ deck: Deck) -> Slot { deck == .a ? a : b }
}
