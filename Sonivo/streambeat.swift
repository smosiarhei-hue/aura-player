@preconcurrency import AVFoundation
import Foundation
import Observation
import AudioToolbox
import MediaToolbox
import StreamAudioProbe

/// C applies realtime EQ and queues chronological overlapping PCM windows from playback.
/// No Swift closures on the media audio thread and no full-file downloads.
@Observable
@MainActor
final class StreamBeatTap {
    static let shared = StreamBeatTap()
    enum EQState { case idle, preparing, ready, unavailable, spatialPassthrough }
    private(set) var activeEQState: EQState = .idle
    private var outcomes: [ObjectIdentifier: EQState] = [:]
    private var desiredGains = [Float](repeating: 0, count: 10)
    private var desiredEnabled = false
    private var waitingSince: TimeInterval = 0
    private final class ProbeContext {
        weak var item: AVPlayerItem?
        var didPrepare = false
        let tap: MTAudioProcessingTap
        init(item: AVPlayerItem, tap: MTAudioProcessingTap) { self.item = item; self.tap = tap }
    }
    private var probes: [ObjectIdentifier: ProbeContext] = [:]
    private var attachments: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var pollingTask: Task<Void, Never>?
    private var activeItemID: ObjectIdentifier?
    private var lastSignal: TimeInterval = 0
    private var hadSignal = false
    private var lastDroppedWindows: UInt64 = 0
    private var latestQueuedMediaTime: TimeInterval?
    private init() {}

    // Explicit state avoids recursive PlayerCore.shared initialization.
    func updateEQ(gains: [Float], enabled: Bool) {
        desiredGains = gains
        desiredEnabled = enabled
        for probe in probes.values { publishEQ(to: probe.tap) }
    }

    private func publishEQ(to tap: MTAudioProcessingTap) {
        desiredGains.withUnsafeBufferPointer {
            SonivoStreamProbeSetEQ(tap, $0.baseAddress!, $0.count, desiredEnabled ? 1 : 0)
        }
    }

    func attach(to item: AVPlayerItem) {
        item.allowedAudioSpatializationFormats = PlayerCore.shared.spatialAudioEnabled ? .monoStereoAndMultichannel : []
        let key = ObjectIdentifier(item)
        guard probes[key] == nil, attachments[key] == nil else { return }
        outcomes[key] = .preparing
        startPolling()
        attachments[key] = Task { [weak self, weak item] in
            guard let self, let item else { return }
            defer { self.attachments[key] = nil }
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                guard !Task.isCancelled else { return }
                guard let track = tracks.first else { self.outcomes[key] = .unavailable; return }
                let descriptions = try await track.load(.formatDescriptions)
                guard !Task.isCancelled else { return }
                // Do not convert encoded Dolby surround to PCM merely to apply EQ.
                if descriptions.contains(where: {
                    let type = CMFormatDescriptionGetMediaSubType($0)
                    return type == kAudioFormatAC3 || type == kAudioFormatEnhancedAC3
                }) {
                    self.outcomes[key] = .spatialPassthrough
                    return
                }
                guard let tap = SonivoStreamProbeCreate() else { self.outcomes[key] = .unavailable; return }
                self.publishEQ(to: tap)
                let input = AVMutableAudioMixInputParameters(track: track)
                input.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [input]
                item.audioMix = mix
                self.probes[key] = ProbeContext(item: item, tap: tap)
                self.startPolling()
            } catch {
                // Protected/live assets may not expose PCM. Never download or interrupt them.
                self.outcomes[key] = .unavailable
            }
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.probes = self.probes.filter { $0.value.item != nil }
                let retained = Set(self.probes.keys).union(self.attachments.keys)
                let currentID = PlayerCore.shared.streamingPlayer.currentItem.map { ObjectIdentifier($0) }
                self.outcomes = self.outcomes.filter { retained.contains($0.key) || $0.key == currentID }
                if self.outcomes.isEmpty && self.probes.isEmpty && self.attachments.isEmpty {
                    self.activeEQState = .idle
                    self.pollingTask = nil
                    return
                }
                if PlayerCore.shared.isPlaying, PlayerCore.shared.usesStreamingBackend,
                   let item = PlayerCore.shared.streamingPlayer.currentItem {
                    let key = ObjectIdentifier(item)
                    if self.activeItemID != key {
                        self.activeItemID = key
                        self.waitingSince = Date.timeIntervalSinceReferenceDate
                        self.hadSignal = false
                        self.latestQueuedMediaTime=nil; self.lastDroppedWindows=0
                        SpectrumAnalyzer.shared.reset()
                    }
                    if let probe = self.probes[key] {
                        let readiness = SonivoStreamProbeEQReady(probe.tap)
                        if readiness == 1 {
                            if !probe.didPrepare { self.publishEQ(to: probe.tap); probe.didPrepare = true }
                            self.outcomes[key] = .ready
                        } else if readiness < 0 || (item.status == .readyToPlay &&
                                  Date.timeIntervalSinceReferenceDate - self.waitingSince > 3) {
                            self.outcomes[key] = .unavailable
                        }
                    }
                    self.activeEQState = self.outcomes[key] ?? .preparing
                    // A preloaded next deck must never drive the audible deck's visuals.
                    self.readSpectrum(from: self.probes[key]?.tap)
                } else if !PlayerCore.shared.usesStreamingBackend {
                    self.activeEQState = .idle
                }
                do { try await Task.sleep(for: .milliseconds(PlayerCore.shared.isPlaying ? 8 : 200)) }
                catch { return }
            }
        }
    }

    // The audible deck's native media clock, not the UI progress timer.
    func currentMediaClock() -> (time: TimeInterval,rate: Double)? {
        let player=PlayerCore.shared.streamingPlayer
        guard PlayerCore.shared.usesStreamingBackend,let item=player.currentItem,
              activeItemID==ObjectIdentifier(item) else { return nil }
        let time=item.currentTime().seconds
        guard time.isFinite,time>=0 else { return nil }
        return (time,player.timeControlStatus == .playing ? Double(player.rate) : 0)
    }

    private func readSpectrum(from tap: MTAudioProcessingTap?) {
        guard let tap else { return }
        guard SpectrumAnalyzer.reserveStreamAnalysis() else { return }
        var windows: [BeatWavePCMWindow] = []
        // Bounded drain per poll; slow analysis leaves PCM in the bounded C queue, not an
        // unbounded DispatchQueue. All windows, including those inside large callbacks, survive.
        for _ in 0..<16 {
            var samples=[Float](repeating: 0,count: 1024)
            var sampleRate=0.0,mediaTime=Double.nan
            let count=samples.withUnsafeMutableBufferPointer {
                SonivoStreamProbeReadTimed(tap,$0.baseAddress!,$0.count,&sampleRate,&mediaTime)
            }
            guard count==1024,sampleRate>0 else { break }
            windows.append(BeatWavePCMWindow(samples: samples,sampleRate: sampleRate,
                mediaTime: mediaTime.isFinite ? mediaTime : nil,observedAt: Date.timeIntervalSinceReferenceDate))
        }
        let dropped=UInt64(SonivoStreamProbeDroppedWindows(tap))
        if dropped != lastDroppedWindows {
            SonivoDiagnostics.log("PCM queue dropped windows=\(dropped)",tag: "BEAT_WAVE")
            lastDroppedWindows=dropped
        }
        SpectrumAnalyzer.submitStreamWindows(windows) // Releases the reserved slot, including empty batches.
        if !windows.isEmpty {
            lastSignal=Date.timeIntervalSinceReferenceDate; hadSignal=true
            latestQueuedMediaTime=windows.last?.mediaTime
        } else if hadSignal && Date.timeIntervalSinceReferenceDate-lastSignal>0.5 {
            // AVPlayer may decode ahead in bursts. No new callback is NOT silence while
            // queued features still belong to future audible media.
            if let queued=latestQueuedMediaTime,let clock=currentMediaClock(),clock.time<=queued { return }
            SpectrumAnalyzer.shared.reset(); hadSignal=false; latestQueuedMediaTime=nil
        }
    }
}
