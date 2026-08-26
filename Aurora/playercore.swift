import AVFoundation
import Combine
import CoreMedia
import MediaPlayer
import SwiftUI

// MARK: - Fast Progressive Audio & Local Playback Engine (PlayerCore)

@MainActor
final class PlayerCore: ObservableObject {
    static let shared = PlayerCore()
    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // MARK: - Published state
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var progress: Double = 0
    @Published private(set) var streamDuration: Double = 0
    @Published private(set) var playError: String?
    @Published var volume: Float = 0.85 {
        didSet {
            streamingPlayer.volume = volume
            engine.mainMixerNode.outputVolume = volume
            defaults.set(volume, forKey: "player.volume")
        }
    }
    @Published var queue: [Track] = []
    @Published var shuffle: Bool = false { didSet { defaults.set(shuffle, forKey: "player.shuffle") } }
    @Published var repeatMode: RepeatMode = .off { didSet { defaults.set(repeatMode.rawValue, forKey: "player.repeat") } }
    @Published var eqEnabled: Bool = true { didSet { applyEQ(); defaults.set(eqEnabled, forKey: "eq.enabled") } }
    @Published var eqGains: [Float] = EQPresets.flat.gains { didSet { applyEQ(); saveEQ() } }

    // Transition Settings
    @Published var transitionMode: TransitionMode = .automix { didSet { defaults.set(transitionMode.rawValue, forKey: "player.transitionMode") } }
    @Published var crossfadeDuration: Double = 3.0 { didSet { defaults.set(crossfadeDuration, forKey: "player.crossfadeDuration") } }

    private let defaults = UserDefaults.standard

    // Instant Streaming Engine (AVPlayer progressive playback in ~150ms)
    private let streamingPlayer = AVPlayer()
    private var timeObserverToken: Any?
    private var isUsingStreamPlayer = false

    // Local Audio Engine (AVAudioEngine + 10-band EQ)
    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private var activePlayer: AVAudioPlayerNode
    private let eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)

    private var activeAudioFile: AVAudioFile?
    private var incomingAudioFile: AVAudioFile?
    private var generation = 0
    private var anchorDate: Date?
    private var anchorOffset: Double = 0
    private var pausedProgress: Double = 0
    private var progressTimer: Timer?

    // AutoMix State
    private var isTransitioning = false
    private var transitionScheduled = false
    private var transitionStartTime: Date?
    private var transitionDuration: Double = 3.0
    private var transitionTimer: Timer?
    private var currentAutoMixStyle: AutoMixStyle = .bassSwapBlend(duration: 3.5)

    var duration: Double {
        if isUsingStreamPlayer {
            if streamDuration > 0 { return streamDuration }
            if let item = streamingPlayer.currentItem {
                let d = CMTimeGetSeconds(item.duration)
                if d.isFinite && d > 0 { return d }
            }
        }
        let trackDur = currentTrack?.duration ?? 0
        return max(trackDur > 0 ? trackDur : streamDuration, 0.001)
    }

    // MARK: - Init
    private init() {
        activePlayer = playerA
        configureSession()
        setupAudioEngine()
        setupStreamingPlayer()
        loadSettings()
        setupRemoteCommandCenter()
    }

    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    private func setupStreamingPlayer() {
        streamingPlayer.automaticallyWaitsToMinimizeStalling = false
        streamingPlayer.volume = volume

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = streamingPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer, self.isPlaying else { return }
                let sec = CMTimeGetSeconds(time)
                if sec.isFinite && sec >= 0 {
                    self.progress = sec

                    if let item = self.streamingPlayer.currentItem {
                        let d = CMTimeGetSeconds(item.duration)
                        if d.isFinite && d > 0 && self.streamDuration != d {
                            self.streamDuration = d
                        }
                    }

                    self.scheduleTransitionIfNeeded()
                    self.updateNowPlayingInfo()
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer else { return }
                // Ignore end-of-track notifications from replaced (stale) AVPlayerItems
                // so the AutoMix asyncAfter transition and this observer don't double-advance.
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                self.handleTrackFinish()
            }
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer else { return }
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                let message = (notification.object as? AVPlayerItem)?.error?.localizedDescription
                self.isPlaying = false
                self.playError = message.map { "Ошибка потока: \($0)" } ?? "Не удалось воспроизвести трек"
            }
        }
    }

    private func setupAudioEngine() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(eqNodeA)
        engine.attach(eqNodeB)

        configureEQ(eqNodeA)
        configureEQ(eqNodeB)

        engine.connect(playerA, to: eqNodeA, format: nil)
        engine.connect(playerB, to: eqNodeB, format: nil)
        engine.connect(eqNodeA, to: engine.mainMixerNode, format: nil)
        engine.connect(eqNodeB, to: engine.mainMixerNode, format: nil)

        engine.mainMixerNode.outputVolume = volume
        try? engine.start()
    }

    private func configureEQ(_ node: AVAudioUnitEQ) {
        for (i, band) in node.bands.enumerated() {
            band.frequency = PlayerCore.bandFrequencies[i]
            band.bandwidth = 1.0
            band.bypass = false
            band.gain = 0
        }
    }

    private func loadSettings() {
        shuffle = defaults.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: defaults.integer(forKey: "player.repeat")) ?? .off
        eqEnabled = defaults.object(forKey: "eq.enabled") as? Bool ?? true

        if let modeStr = defaults.string(forKey: "player.transitionMode"),
           let mode = TransitionMode(rawValue: modeStr) {
            transitionMode = mode
        } else {
            transitionMode = .automix
        }

        crossfadeDuration = defaults.double(forKey: "player.crossfadeDuration")
        if crossfadeDuration <= 0 { crossfadeDuration = 3.0 }

        let savedVol = defaults.float(forKey: "player.volume")
        volume = savedVol > 0 ? savedVol : 0.85
        engine.mainMixerNode.outputVolume = volume
        streamingPlayer.volume = volume

        if let data = defaults.data(forKey: "eq.gains"),
           let gains = try? JSONDecoder().decode([Float].self, from: data),
           gains.count == PlayerCore.bandFrequencies.count {
            eqGains = gains
        }
        applyEQ()
    }

    private func saveEQ() {
        if let data = try? JSONEncoder().encode(eqGains) {
            defaults.set(data, forKey: "eq.gains")
        }
    }

    private func applyEQ() {
        for (i, band) in eqNodeA.bands.enumerated() { band.gain = eqEnabled ? eqGains[i] : 0 }
        for (i, band) in eqNodeB.bands.enumerated() { band.gain = eqEnabled ? eqGains[i] : 0 }
    }

    private var activeEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeA : eqNodeB }
    private var idleEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeB : eqNodeA }
    private var idlePlayer: AVAudioPlayerNode { (activePlayer === playerA) ? playerB : playerA }

    // MARK: - Lockscreen & Remote Commands

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let image = LibraryStore.cachedArtworkImage(for: track) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Playback Controls

    func togglePlay() {
        if currentTrack == nil {
            let source = queue.isEmpty ? LibraryStore.shared.tracks : queue
            if let first = source.first { play(first, newQueue: source) }
            return
        }
        isPlaying ? pause() : resume()
    }

    func play(_ track: Track, newQueue: [Track]? = nil) {
        if let q = newQueue, q != queue { queue = q }
        currentTrack = track
        playError = nil
        streamDuration = track.duration
        cancelTransition()
        start(at: 0)
    }

    func pause() {
        guard isPlaying else { return }
        if isUsingStreamPlayer {
            streamingPlayer.pause()
        } else {
            pausedProgress = liveProgress()
            activePlayer.pause()
            anchorDate = nil
            progress = pausedProgress
        }
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        guard !isPlaying, currentTrack != nil else { return }
        if isUsingStreamPlayer {
            streamingPlayer.play()
            isPlaying = true
        } else {
            if activeAudioFile == nil {
                start(at: pausedProgress)
                return
            }
            if !engine.isRunning { try? engine.start() }
            activePlayer.play()
            isPlaying = true
            anchorDate = Date()
            anchorOffset = pausedProgress
            startTimer()
        }
        updateNowPlayingInfo()
    }

    func next() {
        cancelTransition()
        if let nextTrack = peekNext(auto: false) {
            currentTrack = nextTrack
            streamDuration = nextTrack.duration
            start(at: 0)
        } else if let cur = currentTrack {
            start(at: 0)
            currentTrack = cur
        }
    }

    func previous() {
        cancelTransition()
        let currentPos = isUsingStreamPlayer ? progress : liveProgress()
        if currentPos > 3.0 {
            seek(to: 0)
            return
        }
        let q = effectiveQueue()
        guard let cur = currentTrack,
              let idx = q.firstIndex(where: { $0.id == cur.id }),
              idx > 0 else {
            seek(to: 0)
            return
        }
        currentTrack = q[idx - 1]
        streamDuration = q[idx - 1].duration
        start(at: 0)
    }

    func seek(to seconds: Double) {
        cancelTransition()
        let d = duration
        let clamped = max(0, min(seconds, d))
        progress = clamped

        if isUsingStreamPlayer {
            let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
            streamingPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            pausedProgress = clamped
            anchorOffset = clamped
            if isPlaying {
                start(at: clamped)
            }
        }
        updateNowPlayingInfo()
    }

    func stopAndClear() {
        generation += 1
        streamingPlayer.pause()
        streamingPlayer.replaceCurrentItem(with: nil)
        playerA.stop()
        playerB.stop()
        activeAudioFile = nil
        incomingAudioFile = nil
        currentTrack = nil
        isPlaying = false
        progress = 0
        pausedProgress = 0
        streamDuration = 0
        anchorDate = nil
        cancelTransition()
        SpectrumAnalyzer.shared.reset()
        updateNowPlayingInfo()
    }

    // MARK: - Start Playback (Local Engine or Instant Progressive Streaming)

    private func start(at seconds: Double) {
        guard let track = currentTrack else { return }
        generation += 1
        let token = generation

        cancelTransition()

        // 1. Instant Progressive Online Stream (AVPlayer progressive playback in ~150ms)
        if track.isStream {
            startStream(track, at: seconds, token: token)
            return
        }

        // 2. Local File Playback with Segment Scheduling for Accurate Offset Seeking
        isUsingStreamPlayer = false
        streamingPlayer.pause()
        playerA.stop()
        playerB.stop()
        playerA.volume = 1.0
        playerB.volume = 0.0
        activePlayer = playerA
        applyEQ()

        Task {
            do {
                let audioFile = try AVAudioFile(forReading: track.url)
                self.activeAudioFile = audioFile
                self.incomingAudioFile = nil

                if !self.engine.isRunning {
                    try self.engine.start()
                }

                let sr = audioFile.processingFormat.sampleRate
                let offsetFrames = AVAudioFramePosition(seconds * sr)
                let validOffset = max(0, min(offsetFrames, audioFile.length - 1))
                let frameCount = AVAudioFrameCount(audioFile.length - validOffset)

                self.playerA.scheduleSegment(audioFile, startingFrame: validOffset, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            guard let self, self.generation == token, !self.isUsingStreamPlayer else { return }
                            self.handleTrackFinish()
                        }
                    }
                }

                self.playerA.play()
                self.isPlaying = true
                self.anchorDate = Date()
                self.anchorOffset = seconds
                self.pausedProgress = seconds
                self.progress = seconds
                self.startTimer()
                self.updateNowPlayingInfo()
            } catch {
                self.activeAudioFile = nil
                self.isPlaying = false
                self.playError = "Не удалось открыть аудио: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Stream Resolution (Jamendo direct URL vs Yandex on-demand id)

    private func startStream(_ track: Track, at seconds: Double, token: Int) {
        isUsingStreamPlayer = true
        playerA.stop()
        playerB.stop()

        let url = track.url
        // Jamendo already stores a full https stream URL; Yandex stores only the track id until resolved.
        if url.scheme == "http" || url.scheme == "https" {
            beginStream(url, at: seconds)
            return
        }

        let rawID = track.streamUrlString ?? ""
        let ymID = rawID
            .replacingOccurrences(of: "ym_", with: "")
            .replacingOccurrences(of: ".mp3", with: "")

        Task {
            do {
                let resolved = try await YandexMusicService.shared.getDirectStreamURL(for: ymID)
                guard self.generation == token, self.currentTrack?.id == track.id else { return }
                self.beginStream(resolved, at: seconds)
            } catch {
                guard self.generation == token else { return }
                self.isPlaying = false
                self.playError = "Не удалось открыть поток трека"
            }
        }
    }

    private func beginStream(_ url: URL, at seconds: Double) {
        let item = AVPlayerItem(url: url)
        streamingPlayer.replaceCurrentItem(with: item)
        if seconds > 0 {
            streamingPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        streamingPlayer.play()
        self.isPlaying = true
        self.progress = seconds
        self.updateNowPlayingInfo()
    }

    // MARK: - AutoMix Transitions

    private func scheduleTransitionIfNeeded() {
        guard transitionMode != .off, !isTransitioning, !transitionScheduled, isPlaying else { return }
        let currentPos = isUsingStreamPlayer ? progress : liveProgress()
        let remaining = duration - currentPos

        let targetDuration: Double
        switch transitionMode {
        case .automix:
            if duration > 120 {
                targetDuration = 4.5
                currentAutoMixStyle = .bassSwapBlend(duration: 4.5)
            } else if duration > 45 {
                targetDuration = 3.0
                currentAutoMixStyle = .bassSwapBlend(duration: 3.0)
            } else {
                targetDuration = 1.5
                currentAutoMixStyle = .quickDrop(duration: 1.5)
            }
        case .crossfade:
            targetDuration = crossfadeDuration
            currentAutoMixStyle = .fadeOut(duration: crossfadeDuration)
        case .gapless:
            targetDuration = 0.1
            currentAutoMixStyle = .quickDrop(duration: 0.1)
        case .off:
            return
        }

        guard remaining <= targetDuration, remaining > 0 else { return }
        guard let nextTrack = peekNext(auto: true) else { return }

        // Progressive stream transitions
        if isUsingStreamPlayer || nextTrack.isStream {
            transitionScheduled = true
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self, self.generation == token else { return }
                self.transitionScheduled = false
                self.isTransitioning = false
                self.currentTrack = nextTrack
                self.start(at: 0)
            }
            return
        }

        transitionScheduled = true
        isTransitioning = true
        transitionDuration = targetDuration

        let targetIdlePlayer = idlePlayer
        let token = generation

        Task {
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile

                let frameCount = AVAudioFrameCount(nextFile.length)
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: 0, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.completeTransition(to: nextTrack)
                        }
                    }
                }

                targetIdlePlayer.volume = 0
                if !self.engine.isRunning { try? self.engine.start() }
                targetIdlePlayer.play()

                self.transitionStartTime = Date()
                self.startTransitionTimer()
            } catch {
                self.isTransitioning = false
                self.transitionScheduled = false
            }
        }
    }

    private func startTransitionTimer() {
        transitionTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTransition() }
        }
        RunLoop.main.add(t, forMode: .common)
        transitionTimer = t
    }

    private func tickTransition() {
        guard let start = transitionStartTime, isTransitioning else { return }
        let elapsed = -start.timeIntervalSinceNow
        let p = min(elapsed / transitionDuration, 1.0)

        let outVol = Float(cos(p * .pi / 2))
        let inVol = Float(sin(p * .pi / 2))

        activePlayer.volume = outVol
        idlePlayer.volume = inVol

        if case .bassSwapBlend = currentAutoMixStyle {
            let bassCut = Float(p) * -16.0
            activeEQ.bands[0].gain = eqEnabled ? (eqGains[0] + bassCut) : bassCut
            activeEQ.bands[1].gain = eqEnabled ? (eqGains[1] + bassCut) : bassCut
            activeEQ.bands[2].gain = eqEnabled ? (eqGains[2] + bassCut * 0.7) : (bassCut * 0.7)

            idleEQ.bands[0].gain = eqEnabled ? eqGains[0] : 0
            idleEQ.bands[1].gain = eqEnabled ? eqGains[1] : 0
            idleEQ.bands[2].gain = eqEnabled ? eqGains[2] : 0
        }
    }

    private func completeTransition(to nextTrack: Track) {
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil

        let oldActive = activePlayer
        oldActive.stop()
        oldActive.volume = 1.0

        activePlayer = idlePlayer
        activeAudioFile = incomingAudioFile
        incomingAudioFile = nil
        currentTrack = nextTrack
        anchorDate = Date()
        anchorOffset = 0
        pausedProgress = 0
        progress = 0
        isTransitioning = false
        transitionScheduled = false

        applyEQ()
        updateNowPlayingInfo()
    }

    private func cancelTransition() {
        transitionScheduled = false
        guard isTransitioning else { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil
        idlePlayer.stop()
        idlePlayer.volume = 0
        activePlayer.volume = 1.0
        incomingAudioFile = nil
        isTransitioning = false
        applyEQ()
    }

    // MARK: - Finish & Queue

    private func handleTrackFinish() {
        progress = duration
        anchorDate = nil
        isPlaying = false
        if repeatMode == .one {
            start(at: 0)
            return
        }
        if let nextTrack = peekNext(auto: true) {
            currentTrack = nextTrack
            start(at: 0)
        } else {
            updateNowPlayingInfo()
        }
    }

    private func effectiveQueue() -> [Track] {
        if queue.isEmpty { queue = LibraryStore.shared.tracks }
        return queue
    }

    private func peekNext(auto: Bool) -> Track? {
        let q = effectiveQueue()
        guard !q.isEmpty else { return nil }
        if shuffle {
            if q.count == 1 { return repeatMode == .off && auto ? nil : q[0] }
            let candidates = q.filter { $0.id != currentTrack?.id }
            return candidates.randomElement()
        }
        guard let cur = currentTrack, let idx = q.firstIndex(where: { $0.id == cur.id }) else { return q.first }
        let nextIdx = idx + 1
        if nextIdx < q.count { return q[nextIdx] }
        if repeatMode == .all { return q.first }
        return auto ? nil : q.first
    }

    // MARK: - Progress & Timer

    private func liveProgress() -> Double {
        if let anchor = anchorDate {
            return min(max(0, anchorOffset + (-anchor.timeIntervalSinceNow)), duration)
        }
        return pausedProgress
    }

    private func startTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func tickProgress() {
        guard isPlaying, !isUsingStreamPlayer else { return }
        progress = liveProgress()
        scheduleTransitionIfNeeded()
    }

    func formatted(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Spectrum tap

    func installSpectrumTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            SpectrumAnalyzer.shared.process(buffer: buffer, sampleRate: buffer.format.sampleRate)
        }
    }
}
