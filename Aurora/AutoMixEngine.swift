@preconcurrency import AVFoundation
import Foundation

// MARK: - Real Audio Analysis for DJ-Quality AutoMix
//
// The previous planner only looked at track length and at words in the title,
// with a hard-coded 120 BPM, a hard-coded 0.15 s of tail silence and a 6 second
// ceiling. This engine actually listens to the music: it decodes a mono
// 22.05 kHz amplitude envelope, measures how dense the outro and the intro are,
// detects trailing silence and fade-outs, estimates the tempo by onset
// autocorrelation, and then picks a cue point and a blend length that land on a
// bar boundary.
//
// The next track is fetched and analysed ~45 s before the current one ends, so
// by the time the blend starts we already know both sides of the mix and the
// incoming audio plays from a local file instead of buffering mid-transition.

struct AutoMixProfile: Sendable {
    var duration: Double
    /// Quiet lead-in that should be skipped so the track enters on music.
    var introSkip: Double
    /// Trailing silence that should be covered by the blend.
    var outroSilence: Double
    /// 0...1 loudness density of the closing window.
    var tailEnergy: Double
    /// 0...1 loudness density of the opening window.
    var headEnergy: Double
    var endsWithFade: Bool
    var estimatedBPM: Double?
}

struct AutoMixTransitionPlan: Sendable {
    /// Start the blend this many seconds before the outgoing track ends.
    var leadTime: Double
    /// Blend length in seconds.
    var duration: Double
    /// Seconds of the incoming track to skip.
    var incomingSkip: Double
    var style: DJTransitionStyle

    nonisolated static func fallback(outgoingDuration: Double) -> AutoMixTransitionPlan {
        let blend = min(10.0, max(4.0, outgoingDuration * 0.06))
        return AutoMixTransitionPlan(
            leadTime: blend,
            duration: blend,
            incomingSkip: 0,
            style: .smoothDissolve
        )
    }
}

actor AutoMixEngine {
    static let shared = AutoMixEngine()

    /// Begin fetching and listening to the next track this early.
    static let prepareLeadTime: Double = 45
    /// Hard ceiling for any blend, regardless of what the analysis suggests.
    static let maxBlendDuration: Double = 30

    private let targetSampleRate: Double = 22_050
    private let hopSamples = 1_103                     // ~50 ms per frame
    private let maxPrefetchBytes = 40 * 1024 * 1024
    private let maxCachedFiles = 4

    private var cachedFiles: [String: URL] = [:]
    private var cacheOrder: [String] = []
    private var profiles: [String: AutoMixProfile] = [:]

    private init() {}

    // MARK: - Public API

    /// Cached profile for a track that was analysed earlier, if any.
    func profile(for key: String) -> AutoMixProfile? {
        profiles[key]
    }

    /// Cached local copy for a track that was prefetched earlier, if any.
    func localFile(for key: String) -> URL? {
        guard let url = cachedFiles[key],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Download the track once and analyse it. Safe to call repeatedly.
    func prepare(key: String, remoteURL: URL) async -> AutoMixProfile? {
        if let existing = profiles[key] { return existing }

        guard let local = await localCopy(key: key, remoteURL: remoteURL) else { return nil }
        guard let profile = await analyze(url: local) else { return nil }
        profiles[key] = profile
        return profile
    }

    /// Pure planning step. Combines both sides of the mix into a cue point,
    /// a blend length and a DJ style.
    nonisolated func plan(
        outgoing: AutoMixProfile?,
        incoming: AutoMixProfile?,
        outgoingDuration: Double,
        preferredStyle: DJTransitionStyle,
        maxDuration: Double
    ) -> AutoMixTransitionPlan {
        guard outgoingDuration > 10 else {
            return AutoMixTransitionPlan.fallback(outgoingDuration: outgoingDuration)
        }

        let tail = outgoing?.tailEnergy ?? 0.4
        let head = incoming?.headEnergy ?? 0.4
        let fades = outgoing?.endsWithFade ?? false
        let silence = min(outgoing?.outroSilence ?? 0, 12)

        var blend: Double
        var style: DJTransitionStyle

        if fades {
            // The track already fades itself - ride that fade instead of
            // fighting it, and bring the next one up underneath.
            blend = 14
            style = .smoothDissolve
        } else if tail > 0.60 && head > 0.50 {
            // Dense ending into a strong opening: the long, satisfying DJ blend.
            blend = 18
            style = .bassSwap
        } else if tail > 0.35 {
            blend = 12
            style = .bassSwap
        } else if head < 0.15 {
            // The next track opens quietly, a long blend would just sound empty.
            blend = 5
            style = .quickDrop
        } else {
            blend = 9
            style = .smoothDissolve
        }

        if preferredStyle != .adaptiveAI {
            style = preferredStyle
        }

        // Snap the blend onto a bar boundary so the beats do not drift apart.
        if let bpm = outgoing?.estimatedBPM, bpm > 40, bpm < 220 {
            let bar = (60.0 / bpm) * 4.0
            if bar > 0.4 {
                let bars = max(1.0, (blend / bar).rounded())
                blend = bars * bar
            }
        }

        let ceiling = min(
            Self.maxBlendDuration,
            min(max(maxDuration, 8), outgoingDuration * 0.33)
        )
        blend = min(max(blend, 3), ceiling)

        // Start early enough that trailing silence is swallowed by the blend.
        let leadTime = min(blend + silence, outgoingDuration * 0.45)

        return AutoMixTransitionPlan(
            leadTime: leadTime,
            duration: blend,
            incomingSkip: min(incoming?.introSkip ?? 0, 12),
            style: style
        )
    }

    // MARK: - Prefetch

    private func localCopy(key: String, remoteURL: URL) async -> URL? {
        if let cached = localFile(for: key) { return cached }

        if remoteURL.isFileURL {
            return FileManager.default.fileExists(atPath: remoteURL.path) ? remoteURL : nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoMixCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var ext = remoteURL.pathExtension
        if ext.isEmpty { ext = "mp3" }
        let destination = directory.appendingPathComponent(UUID().uuidString + "." + ext)

        guard let (temp, response) = try? await URLSession.shared.download(from: remoteURL) else {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let expected = Int(response.expectedContentLength)
        if size > maxPrefetchBytes || expected > maxPrefetchBytes {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }

        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(at: temp, to: destination)) != nil else {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }

        cachedFiles[key] = destination
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        trimCache()
        return destination
    }

    private func trimCache() {
        while cacheOrder.count > maxCachedFiles {
            let oldest = cacheOrder.removeFirst()
            if let url = cachedFiles.removeValue(forKey: oldest) {
                try? FileManager.default.removeItem(at: url)
            }
            profiles.removeValue(forKey: oldest)
        }
    }

    // MARK: - Analysis

    private func analyze(url: URL) async -> AutoMixProfile? {
        guard let (envelope, frameRate, duration) = await envelope(for: url),
              !envelope.isEmpty, frameRate > 0, duration > 1 else { return nil }
        return profile(from: envelope, frameRate: frameRate, duration: duration)
    }

    private func envelope(for url: URL) async -> (values: [Float], frameRate: Double, duration: Double)? {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }

        let seconds: Double
        if let loaded = try? await asset.load(.duration) {
            seconds = CMTimeGetSeconds(loaded)
        } else {
            return nil
        }
        guard seconds.isFinite, seconds > 1 else { return nil }

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: targetSampleRate
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var values: [Float] = []
        var peak: Float = 0
        var counted = 0

        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                )
                if let pointer, length >= 4 {
                    let count = length / 4
                    let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
                    for index in 0..<count {
                        peak = max(peak, abs(floats[index]))
                        counted += 1
                        if counted == hopSamples {
                            values.append(peak)
                            peak = 0
                            counted = 0
                        }
                    }
                }
            }
            CMSampleBufferInvalidate(sample)
        }

        if counted > 0 { values.append(peak) }
        reader.cancelReading()

        guard values.count > 8 else { return nil }
        return (values, targetSampleRate / Double(hopSamples), seconds)
    }

    private func profile(from values: [Float], frameRate: Double, duration: Double) -> AutoMixProfile {
        let maxValue = values.max() ?? 0
        guard maxValue > 0 else {
            return AutoMixProfile(
                duration: duration,
                introSkip: 0,
                outroSilence: 0,
                tailEnergy: 0,
                headEnergy: 0,
                endsWithFade: false,
                estimatedBPM: nil
            )
        }

        let silenceLevel = maxValue * 0.02
        let activeLevel = maxValue * 0.25

        var leading = 0
        while leading < values.count, values[leading] < silenceLevel { leading += 1 }
        var trailing = 0
        while trailing < values.count, values[values.count - 1 - trailing] < silenceLevel { trailing += 1 }

        let introSkip = min(Double(leading) / frameRate, 12)
        let outroSilence = min(Double(trailing) / frameRate, 15)

        func density(_ slice: ArraySlice<Float>) -> Double {
            guard !slice.isEmpty else { return 0 }
            let loud = slice.reduce(0) { $0 + ($1 >= activeLevel ? 1 : 0) }
            return Double(loud) / Double(slice.count)
        }

        // Closing window, ignoring the trailing silence itself.
        let tailEnd = max(0, values.count - trailing)
        let tailStart = max(0, tailEnd - Int(45 * frameRate))
        let tailEnergy = density(values[tailStart..<tailEnd])

        // Opening window, ignoring the quiet lead-in.
        let headStart = min(leading, values.count)
        let headEnd = min(values.count, headStart + Int(30 * frameRate))
        let headEnergy = density(values[headStart..<headEnd])

        // Fade detection: is the last stretch clearly quieter than the one before?
        var endsWithFade = false
        let window = Int(12 * frameRate)
        if tailEnd - tailStart > window * 2, window > 4 {
            let last = values[(tailEnd - window)..<tailEnd]
            let previous = values[(tailEnd - window * 2)..<(tailEnd - window)]
            let lastMean = last.reduce(0, +) / Float(last.count)
            let previousMean = previous.reduce(0, +) / Float(previous.count)
            if previousMean > 0, lastMean < previousMean * 0.55 { endsWithFade = true }
        }

        return AutoMixProfile(
            duration: duration,
            introSkip: introSkip,
            outroSilence: outroSilence,
            tailEnergy: tailEnergy,
            headEnergy: headEnergy,
            endsWithFade: endsWithFade,
            estimatedBPM: estimateBPM(values: values, frameRate: frameRate)
        )
    }

    /// Tempo from onset-flux autocorrelation over the 60-190 BPM range.
    private func estimateBPM(values: [Float], frameRate: Double) -> Double? {
        guard values.count > Int(frameRate * 12) else { return nil }

        var flux: [Double] = []
        flux.reserveCapacity(values.count)
        for index in 1..<values.count {
            flux.append(max(0, Double(values[index] - values[index - 1])))
        }
        guard flux.count > 16 else { return nil }

        let mean = flux.reduce(0, +) / Double(flux.count)
        guard mean > 0 else { return nil }
        let centred = flux.map { $0 - mean }

        let minLag = max(1, Int(frameRate * 60.0 / 190.0))
        let maxLag = min(centred.count - 1, Int(frameRate * 60.0 / 60.0))
        guard maxLag > minLag else { return nil }

        var bestLag = 0
        var bestScore = 0.0
        for lag in minLag...maxLag {
            var score = 0.0
            var index = 0
            while index + lag < centred.count {
                score += centred[index] * centred[index + lag]
                index += 1
            }
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        guard bestLag > 0, bestScore > 0 else { return nil }
        let bpm = 60.0 * frameRate / Double(bestLag)
        guard bpm.isFinite, bpm > 55, bpm < 200 else { return nil }
        return bpm
    }
}
