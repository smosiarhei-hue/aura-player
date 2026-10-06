@preconcurrency import AVFoundation
import Foundation
import MediaToolbox
import StreamAudioProbe

/// C captures only the latest 1024 samples from audio already being played.
/// No Swift closures on the media audio thread and no full-file downloads.
@MainActor
final class StreamBeatTap {
    static let shared = StreamBeatTap()
    private final class ProbeContext {
        weak var item: AVPlayerItem?
        let tap: MTAudioProcessingTap
        init(item: AVPlayerItem, tap: MTAudioProcessingTap) { self.item = item; self.tap = tap }
    }
    private var probes: [ObjectIdentifier: ProbeContext] = [:]
    private var attachments: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var pollingTask: Task<Void, Never>?
    private var activeItemID: ObjectIdentifier?
    private var lastSignal: TimeInterval = 0
    private var hadSignal = false
    private init() {}

    func attach(to item: AVPlayerItem) {
        item.allowedAudioSpatializationFormats = PlayerCore.shared.spatialAudioEnabled ? .monoStereoAndMultichannel : []
        let key = ObjectIdentifier(item)
        guard probes[key] == nil, attachments[key] == nil else { return }
        attachments[key] = Task { [weak self, weak item] in
            guard let self, let item else { return }
            defer { self.attachments[key] = nil }
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                guard !Task.isCancelled, let track = tracks.first,
                      let tap = SonivoStreamProbeCreate() else { return }
                let input = AVMutableAudioMixInputParameters(track: track)
                input.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [input]
                item.audioMix = mix
                self.probes[key] = ProbeContext(item: item, tap: tap)
                self.startPolling()
            } catch {
                // Some protected/live assets do not expose PCM. Playback is unchanged.
            }
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.probes = self.probes.filter { $0.value.item != nil }
                if self.probes.isEmpty { self.pollingTask = nil; return }
                if PlayerCore.shared.isPlaying, PlayerCore.shared.currentTrack?.isStream == true,
                   let item = PlayerCore.shared.streamingPlayer.currentItem {
                    let key = ObjectIdentifier(item)
                    if self.activeItemID != key {
                        self.activeItemID = key
                        self.hadSignal = false
                        SpectrumAnalyzer.shared.reset()
                    }
                    // A preloaded next deck must never drive the audible deck's visuals.
                    self.readSpectrum(from: self.probes[key]?.tap)
                }
                do { try await Task.sleep(for: .milliseconds(PlayerCore.shared.isPlaying ? 25 : 200)) }
                catch { return }
            }
        }
    }

    private func readSpectrum(from tap: MTAudioProcessingTap?) {
        guard let tap else { return }
        var samples = [Float](repeating: 0, count: 1024)
        var sampleRate = 0.0
        let count = samples.withUnsafeMutableBufferPointer {
            SonivoStreamProbeRead(tap, $0.baseAddress!, $0.count, &sampleRate)
        }
        if count == 1024, sampleRate > 0,
           let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
           let channel = buffer.floatChannelData?[0] {
            buffer.frameLength = 1024
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: 1024) }
            SpectrumAnalyzer.ingest(buffer: buffer, sampleRate: sampleRate)
            lastSignal = Date.timeIntervalSinceReferenceDate
            hadSignal = true
        } else if hadSignal && Date.timeIntervalSinceReferenceDate - lastSignal > 0.5 {
            SpectrumAnalyzer.shared.reset()
            hadSignal = false
        }
    }
}
