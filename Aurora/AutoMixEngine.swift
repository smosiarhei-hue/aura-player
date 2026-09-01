import AVFoundation
import CoreMedia
import Foundation

// MARK: - Analysis results

/// Loudness/structure summary of one track, measured from decoded audio.
struct AutoMixProfile: Sendable {
    var duration: Double
    /// Quiet lead-in that should be trimmed so the incoming track enters on music.
    var introSkip: Double
    /// Trailing silence at the end of the outgoing track.
    var outroSilence: Double
    /// Normalized loudness of the last musical seconds (0...1).
    var tailEnergy: Double
    /// Normalized loudness of the first musical seconds (0...1).
    var headEnergy: Double
    /// True when the track ends on a long fade-out rather than a hard stop.
    var endsWithFade: Bool
    var estimatedBPM: Double?
}

/// Concrete instruction for one transition.
struct AutoMixPlan: Sendable {
    /// How many seconds before the end of the outgoing track the blend starts.
    var leadTime: Double
    /// Length of the blend itself.
    var duration: Double
    /// Quiet intro of the incoming track to skip.
    var incomingSkip: Double
    var style: AutoMixStyle
    /// Human-readable reason, useful for debugging and for the UI.
    var reason: String

    static func fallback(currentDuration: Double, nextDuration: Double) -> AutoMixPlan {
        let shortest = min(max(currentDuration, 1), max(nextDuration, 1))
        if shortest > 150 {
            return AutoMixPlan(leadTime: 9, duration: 9, incomingSkip: 0, style: .bassSwapBlend(duration: 9), reason: "\u{0431}\u{0430}\u{0437}\u{043e}\u{0432}\u{044b}\u{0439} \u{0441}\u{0432}\u{0435}\u{0434}\u{0435}\u{043d}\u{0438}\u{0435}")
        }
        if shortest > 60 {
            return AutoMixPlan(leadTime: 6, duration: 6, incomingSkip: 0, style: .bassSwapBlend(duration: 6), reason: "\u{043a}\u{043e}\u{0440}\u{043e}\u{0442}\u{043a}\u{0438}\u{0435} \u{0442}\u{0440}\u{0435}\u{043a}\u{0438}")
        }
        return AutoMixPlan(leadTime: 2.5, duration: 2.5, incomingSkip: 0, style: .quickDrop(duration: 2.5), reason: "\u{043e}\u{0447}\u{0435}\u{043d}\u{044c} \u{043a}\u{043e}\u{0440}\u{043e}\u{0442}\u{043a}\u{0438}\u{0435} \u{0442}\u{0440}\u{0435}\u{043a}\u{0438}")
    }
}

/// Everything PlayerCore needs to perform a prepared transition.
struct AutoMixPreparation: Sendable {
    var plan: AutoMixPlan
    /// Local copy of the incoming track, when it could be cached ahead of time.
    var localURL: URL?
    var profile: AutoMixProfile?
}

// MARK: - Engine

/// Listens to the upcoming track before it plays, then decides where and how
/// to blend out of the current one.
actor AutoMixEngine {
    static let shared = AutoMixEngine()

    /// Analysis starts this many seconds before the current track ends, so the
    /// decision and the prefetched audio are ready well ahead of the blend.
    static let prepareLeadTime: Double = 45

    private static let sampleRate: Double = 22_050
    private static let hopSamples = 1_103 // ~50 ms
    private static let hopSeconds = Double(hopSamples) / sampleRate
    private static let headWindow: Double = 40
    private static let tailWindow: Double = 60
    private static let maxPrefetchBytes: Int64 = 30 * 1024 * 1024

    private var profiles: [UUID: AutoMixProfile] = [:]
    private var localCopies: [UUID: URL] = [:]
    private var order: [UUID] = []

    // MARK: Public API

    func prepare(
        trackID: UUID,
        url: URL,
        isRemote: Bool,
        currentProfile: AutoMixProfile?,
        currentDuration: Double,
        nextDuration: Double
    ) async -> AutoMixPreparation {
        if let cached = profiles[trackID] {
            return AutoMixPreparation(
                plan: Self.plan(outgoing: currentProfile, incoming: cached, currentDuration: currentDuration, nextDuration: nextDuration),
                localURL: localCopies[trackID],
                profile: cached
            )
        }

        var analysisURL = url
        var localURL: URL?

        if isRemote {
            localURL = await Self.prefetch(from: url, trackID: trackID)
            if let localURL { analysisURL = localURL }
        }

        let profile = isRemote && localURL == nil
            ? nil
            : await Self.profile(fileURL: analysisURL)

        remember(trackID: trackID, profile: profile, localURL: localURL)

        return AutoMixPreparation(
            plan: Self.plan(outgoing: currentProfile, incoming: profile, currentDuration: currentDuration, nextDuration: nextDuration),
            localURL: localURL,
            profile: profile
        )
    }

    /// Profile for a track that is already available locally, used for the
    /// outgoing side of a blend.
    func profile(trackID: UUID, url: URL) async -> AutoMixProfile? {
        if let cached = profiles[trackID] { return cached }
        guard url.isFileURL else { return nil }
        let measured = await Self.profile(fileURL: url)
        remember(trackID: trackID, profile: measured, localURL: nil)
        return measured
    }

    func cachedProfile(trackID: UUID) -> AutoMixProfile? { profiles[trackID] }

    func localCopy(trackID: UUID) -> URL? { localCopies[trackID] }

    func discardLocalCopy(trackID: UUID) {
        guard let url = localCopies.removeValue(forKey: trackID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Cache bookkeeping

    private func remember(trackID: UUID, profile: AutoMixProfile?, localURL: URL?) {
        if let profile { profiles[trackID] = profile }
        if let localURL { localCopies[trackID] = localURL }
        order.removeAll { $0 == trackID }
        order.append(trackID)

        while order.count > 4 {
            let stale = order.removeFirst()
            profiles.removeValue(forKey: stale)
            if let url = localCopies.removeValue(forKey: stale) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Decision

    nonisolated static func plan(
        outgoing: AutoMixProfile?,
        incoming: AutoMixProfile?,
        currentDuration: Double,
        nextDuration: Double
    ) -> AutoMixPlan {
        guard let incoming else {
            return .fallback(currentDuration: currentDuration, nextDuration: nextDuration)
        }

        let tailEnergy = outgoing?.tailEnergy ?? 0.30
        let headEnergy = incoming.headEnergy
        let endsWithFade = outgoing?.endsWithFade ?? false
        let outroSilence = outgoing?.outroSilence ?? 0

        var lead: Double
        var style: AutoMixStyle
        var reason: String

        if endsWithFade {
            // The outgoing track already fades itself, so ride its fade and let
            // the new track grow underneath it.
            lead = 13
            style = .fadeOut(duration: 13)
            reason = "\u{0443}\u{0445}\u{043e}\u{0434}\u{044f}\u{0449}\u{0438}\u{0439} \u{0442}\u{0440}\u{0435}\u{043a} \u{0441}\u{0430}\u{043c} \u{0437}\u{0430}\u{0442}\u{0443}\u{0445}\u{0430}\u{0435}\u{0442}"
        } else if tailEnergy > 0.34 && headEnergy > 0.26 {
            // Both sides are loud: the long DJ-style bass swap.
            lead = 16
            style = .bassSwapBlend(duration: 16)
            reason = "\u{043f}\u{043b}\u{043e}\u{0442}\u{043d}\u{044b}\u{0439} \u{0444}\u{0438}\u{043d}\u{0430}\u{043b} \u{0438} \u{0433}\u{0440}\u{043e}\u{043c}\u{043a}\u{043e}\u{0435} \u{043d}\u{0430}\u{0447}\u{0430}\u{043b}\u{043e}"
        } else if tailEnergy > 0.20 && headEnergy > 0.14 {
            lead = 10
            style = .bassSwapBlend(duration: 10)
            reason = "\u{0441}\u{0440}\u{0435}\u{0434}\u{043d}\u{044f}\u{044f} \u{043f}\u{043b}\u{043e}\u{0442}\u{043d}\u{043e}\u{0441}\u{0442}\u{044c}"
        } else if headEnergy < 0.10 {
            // Soft intro: a long blend would sound like a gap, so stay short.
            lead = 4
            style = .quickDrop(duration: 4)
            reason = "\u{0442}\u{0438}\u{0445}\u{043e}\u{0435} \u{043d}\u{0430}\u{0447}\u{0430}\u{043b}\u{043e} \u{0441}\u{043b}\u{0435}\u{0434}\u{0443}\u{044e}\u{0449}\u{0435}\u{0433}\u{043e}"
        } else {
            lead = 7
            style = .bassSwapBlend(duration: 7)
            reason = "\u{0441}\u{043f}\u{043e}\u{043a}\u{043e}\u{0439}\u{043d}\u{044b}\u{0439} \u{0444}\u{0438}\u{043d}\u{0430}\u{043b}"
        }

        // Silence at the end is dead air; start early enough to cover it.
        if outroSilence > 0.4 {
            lead = max(lead, min(outroSilence + 5, 20))
        }

        // Snap the blend to whole bars so beats stay aligned.
        if let bpm = outgoing?.estimatedBPM ?? incoming.estimatedBPM, bpm > 50, bpm < 200 {
            let bar = (60.0 / bpm) * 4.0
            if bar > 0.5 {
                let bars = max(1, (lead / bar).rounded())
                lead = bars * bar
            }
        }

        // Never eat more than a third of either track.
        let ceiling = min(
            max(currentDuration, 1) * 0.33,
            max(nextDuration > 0 ? nextDuration : incoming.duration, 1) * 0.33
        )
        lead = min(max(lead, 2), min(ceiling, 30))

        let incomingSkip = min(max(incoming.introSkip, 0), 12)

        return AutoMixPlan(
            leadTime: lead,
            duration: lead,
            incomingSkip: incomingSkip,
            style: Self.restyled(style, duration: lead),
            reason: reason
        )
    }

    nonisolated private static func restyled(_ style: AutoMixStyle, duration: Double) -> AutoMixStyle {
        switch style {
        case .bassSwapBlend: return .bassSwapBlend(duration: duration)
        case .quickDrop: return .quickDrop(duration: duration)
        case .fadeOut: return .fadeOut(duration: duration)
        }
    }

    // MARK: Measurement

    nonisolated static func profile(fileURL: URL) async -> AutoMixProfile? {
        let asset = AVURLAsset(url: fileURL)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 3 else { return nil }

        let headEnd = min(Self.headWindow, seconds)
        let tailStart = max(0, seconds - Self.tailWindow)

        let head = await envelope(
            asset: asset,
            range: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: headEnd, preferredTimescale: 600)
            )
        )

        let tail: [Double]
        if tailStart <= headEnd {
            tail = head
        } else {
            tail = await envelope(
                asset: asset,
                range: CMTimeRange(
                    start: CMTime(seconds: tailStart, preferredTimescale: 600),
                    duration: CMTime(seconds: seconds - tailStart, preferredTimescale: 600)
                )
            )
        }

        guard !head.isEmpty || !tail.isEmpty else { return nil }

        let peak = max(head.max() ?? 0, tail.max() ?? 0)
        guard peak > 0 else { return nil }

        let silence = peak * 0.02 // about -34 dB relative to peak

        let introSkip = Double(head.prefix(while: { $0 < silence }).count) * hopSeconds
        let outroSilence = Double(tail.reversed().prefix(while: { $0 < silence }).count) * hopSeconds

        let musicalHead = head.drop(while: { $0 < silence }).prefix(Int(10 / hopSeconds))
        let headEnergy = musicalHead.isEmpty ? 0 : (musicalHead.reduce(0, +) / Double(musicalHead.count)) / peak

        var musicalTail = Array(tail)
        while let last = musicalTail.last, last < silence { musicalTail.removeLast() }
        let tailSlice = musicalTail.suffix(Int(10 / hopSeconds))
        let tailEnergy = tailSlice.isEmpty ? 0 : (tailSlice.reduce(0, +) / Double(tailSlice.count)) / peak

        return AutoMixProfile(
            duration: seconds,
            introSkip: introSkip,
            outroSilence: outroSilence,
            tailEnergy: min(max(tailEnergy, 0), 1),
            headEnergy: min(max(headEnergy, 0), 1),
            endsWithFade: detectFade(in: musicalTail, peak: peak),
            estimatedBPM: estimateBPM(from: musicalTail.isEmpty ? head : musicalTail)
        )
    }

    nonisolated private static func detectFade(in tail: [Double], peak: Double) -> Bool {
        let frames = Int(10 / hopSeconds)
        guard tail.count > frames else { return false }
        let window = Array(tail.suffix(frames))
        let half = window.count / 2
        guard half > 2 else { return false }
        let firstHalf = window.prefix(half).reduce(0, +) / Double(half)
        let secondHalf = window.suffix(half).reduce(0, +) / Double(half)
        guard firstHalf > peak * 0.06 else { return false }
        return secondHalf < firstHalf * 0.55
    }

    nonisolated private static func estimateBPM(from envelope: [Double]) -> Double? {
        guard envelope.count > 60 else { return nil }

        // Onset strength: positive change in loudness.
        var flux: [Double] = []
        flux.reserveCapacity(envelope.count)
        for index in 1..<envelope.count {
            flux.append(max(0, envelope[index] - envelope[index - 1]))
        }
        let mean = flux.reduce(0, +) / Double(flux.count)
        guard mean > 0 else { return nil }
        let centered = flux.map { $0 - mean }

        // Autocorrelation over beat periods from 60 to 190 BPM.
        let minLag = Int((60.0 / 190.0) / hopSeconds)
        let maxLag = Int((60.0 / 60.0) / hopSeconds)
        guard maxLag < centered.count, minLag >= 1, minLag < maxLag else { return nil }

        var bestLag = 0
        var bestScore = 0.0
        for lag in minLag...maxLag {
            var score = 0.0
            for index in 0..<(centered.count - lag) {
                score += centered[index] * centered[index + lag]
            }
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        guard bestLag > 0, bestScore > 0 else { return nil }
        let bpm = 60.0 / (Double(bestLag) * hopSeconds)
        return bpm.isFinite ? bpm : nil
    }

    nonisolated private static func envelope(asset: AVURLAsset, range: CMTimeRange) async -> [Double] {
        guard
            let tracks = try? await asset.loadTracks(withMediaType: .audio),
            let audioTrack = tracks.first,
            let reader = try? AVAssetReader(asset: asset)
        else { return [] }

        reader.timeRange = range

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var result: [Double] = []
        var accumulator = 0.0
        var counted = 0

        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var totalLength = 0
                var pointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &pointer
                ) == kCMBlockBufferNoErr, let pointer {
                    let count = totalLength / 4
                    let samples = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
                    for index in 0..<count {
                        let value = Double(samples[index])
                        accumulator += value * value
                        counted += 1
                        if counted == hopSamples {
                            result.append((accumulator / Double(hopSamples)).squareRoot())
                            accumulator = 0
                            counted = 0
                        }
                    }
                }
            }
            CMSampleBufferInvalidate(sample)
        }

        if counted > 0 {
            result.append((accumulator / Double(counted)).squareRoot())
        }

        reader.cancelReading()
        return result
    }

    // MARK: Prefetch

    /// Downloads the upcoming track so it can be analyzed and then played from
    /// disk, which also removes the buffering hitch at the transition.
    nonisolated private static func prefetch(from url: URL, trackID: UUID) async -> URL? {
        guard !url.isFileURL else { return url }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                try? FileManager.default.removeItem(at: temporaryURL)
                return nil
            }
            if response.expectedContentLength > maxPrefetchBytes {
                try? FileManager.default.removeItem(at: temporaryURL)
                return nil
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AutoMixCache", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let suffix = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let destination = directory.appendingPathComponent("\(trackID.uuidString).\(suffix)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
