import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

@MainActor
final class PlayerCore: ObservableObject {
    static let shared = PlayerCore()
    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // MARK: - Published state
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var progress: Double = 0
    @Published private(set) var playError: String?
    @Published var volume: Float = 0.85 {
        didSet {
            engine.mainMixerNode.outputVolume = volume
            defaults.set(volume, forKey: "player.volume")
        }
    }
    @Published var queue: [Track] = []
    @Published var shuffle: Bool = false { didSet { defaults.set(shuffle, forKey: "player.shuffle") } }
    @Published var repeatMode: RepeatMode = .off { didSet { defaults.set(repeatMode.rawValue, forKey: "player.repeat") } }
    @Published var eqEnabled: Bool = true { didSet { applyEQ(); defaults.set(eqEnabled, forKey: "eq.enabled") } }
    @Published var eqGains: [Float] = EQPresets.flat.gains { didSet { applyEQ(); saveEQ() } }
    @Published var automixEnabled: Bool = true { didSet { defaults.set(automixEnabled, forKey: "player.automix") } }
    @Published var automixDuration: Double = 3.0 { didSet { defaults.set(automixDuration, forKey: "player.automixDuration") } }

    private let defaults = UserDefaults.standard
    private let engine = AVAudioEngine()

    // Dual players for seamless crossfade
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private var activePlayer: AVAudioPlayerNode

    private let eqNode = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)

    private var activeAudioFile: AVAudioFile?
    private var incomingAudioFile: AVAudioFile?
    private var generation = 0
    private var anchorDate: Date?
    private var anchorOffset: Double = 0
    private var pausedProgress: Double = 0
    private var progressTimer: Timer?

    // Crossfade State
    private var isCrossfading = false
    private var crossfadeScheduled = false
    private var crossfadeStartTime: Date?
    private var crossfadeTimer: Timer?

    var duration: Double { max(currentTrack?.duration ?? 0, 0.001) }

    // MARK: - Init
    private init() {
        activePlayer = playerA
        configureSession()
        setupAudioEngine()
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

    private func setupAudioEngine() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(eqNode)

        for (i, band) in eqNode.bands.enumerated() {
            band.frequency = PlayerCore.bandFrequencies[i]
            band.bandwidth = 1.0
            band.bypass = false
            band.gain = 0
        }

        engine.connect(playerA, to: eqNode, format: nil)
        engine.connect(playerB, to: eqNode, format: nil)
        engine.connect(eqNode, to: engine.mainMixerNode, format: nil)

        engine.mainMixerNode.outputVolume = volume
        try? engine.start()
    }

    private func loadSettings() {
        shuffle = defaults.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: defaults.integer(forKey: "player.repeat")) ?? .off
        eqEnabled = defaults.object(forKey: "eq.enabled") as? Bool ?? true
        automixEnabled = defaults.object(forKey: "player.automix") as? Bool ?? true
        automixDuration = defaults.double(forKey: "player.automixDuration")
        if automixDuration <= 0 { automixDuration = 3.0 }

        let savedVol = defaults.float(forKey: "player.volume")
        volume = savedVol > 0 ? savedVol : 0.85
        engine.mainMixerNode.outputVolume = volume

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
        for (i, band) in eqNode.bands.enumerated() {
            band.gain = eqEnabled ? eqGains[i] : 0
        }
    }

    // MARK: - Lockscreen & Now Playing Remote Command Center

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
        cancelCrossfade()
        start(at: 0)
    }

    func pause() {
        guard isPlaying else { return }
        pausedProgress = liveProgress()
        activePlayer.pause()
        isPlaying = false
        anchorDate = nil
        progress = pausedProgress
        updateNowPlayingInfo()
    }

    func resume() {
        guard !isPlaying, currentTrack != nil else { return }
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
        updateNowPlayingInfo()
    }

    func next() {
        cancelCrossfade()
        if let nextTrack = peekNext(auto: false) {
            currentTrack = nextTrack
            start(at: 0)
        } else if let cur = currentTrack {
            start(at: 0)
            currentTrack = cur
        }
    }

    func previous() {
        cancelCrossfade()
        let currentPos = liveProgress()
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
        start(at: 0)
    }

    func seek(to seconds: Double) {
        cancelCrossfade()
        let clamped = max(0, min(seconds, duration))
        if isPlaying {
            start(at: clamped)
        } else {
            pausedProgress = clamped
            progress = clamped
            anchorOffset = clamped
            updateNowPlayingInfo()
        }
    }

    func stopAndClear() {
        generation += 1
        playerA.stop()
        playerB.stop()
        activeAudioFile = nil
        incomingAudioFile = nil
        currentTrack = nil
        isPlaying = false
        progress = 0
        pausedProgress = 0
        anchorDate = nil
        cancelCrossfade()
        SpectrumAnalyzer.shared.reset()
        updateNowPlayingInfo()
    }

    // MARK: - Internal Playback Setup

    private func start(at seconds: Double) {
        guard let track = currentTrack else { return }
        generation += 1
        let token = generation

        cancelCrossfade()
        playerA.stop()
        playerB.stop()
        playerA.volume = 1.0
        playerB.volume = 0.0
        activePlayer = playerA

        Task {
            do {
                let fileURL: URL
                if track.isStream {
                    let (tmpUrl, _) = try await URLSession.shared.download(from: track.url)
                    fileURL = tmpUrl
                } else {
                    fileURL = track.url
                }

                let audioFile = try AVAudioFile(forReading: fileURL)
                self.activeAudioFile = audioFile
                self.incomingAudioFile = nil

                if !self.engine.isRunning {
                    try self.engine.start()
                }

                let sr = audioFile.processingFormat.sampleRate
                let offsetFrames = AVAudioFramePosition(seconds * sr)
                audioFile.framePosition = max(0, min(offsetFrames, audioFile.length - 1))

                self.playerA.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
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

    // MARK: - Automix / Crossfade

    private func scheduleCrossfadeIfNeeded() {
        guard automixEnabled, !isCrossfading, !crossfadeScheduled, isPlaying else { return }
        let remaining = duration - liveProgress()
        guard remaining <= automixDuration, remaining > 0 else { return }
        guard let nextTrack = peekNext(auto: true) else { return }

        crossfadeScheduled = true
        isCrossfading = true

        let idlePlayer = (activePlayer === playerA) ? playerB : playerA
        let token = generation

        Task {
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile

                idlePlayer.scheduleFile(nextFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.completeCrossfade(to: nextTrack)
                        }
                    }
                }

                idlePlayer.volume = 0
                if !self.engine.isRunning { try? self.engine.start() }
                idlePlayer.play()

                self.crossfadeStartTime = Date()
                self.startCrossfadeTimer()
            } catch {
                self.isCrossfading = false
                self.crossfadeScheduled = false
            }
        }
    }

    private func startCrossfadeTimer() {
        crossfadeTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCrossfade() }
        }
        RunLoop.main.add(t, forMode: .common)
        crossfadeTimer = t
    }

    private func tickCrossfade() {
        guard let start = crossfadeStartTime, isCrossfading else { return }
        let elapsed = -start.timeIntervalSinceNow
        let p = min(elapsed / automixDuration, 1.0)

        // Equal power crossfade curve
        let outVol = Float(cos(p * .pi / 2))
        let inVol = Float(sin(p * .pi / 2))

        activePlayer.volume = outVol
        let idlePlayer = (activePlayer === playerA) ? playerB : playerA
        idlePlayer.volume = inVol
    }

    private func completeCrossfade(to nextTrack: Track) {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeStartTime = nil

        let oldActive = activePlayer
        oldActive.stop()
        oldActive.volume = 1.0

        activePlayer = (activePlayer === playerA) ? playerB : playerA
        activeAudioFile = incomingAudioFile
        incomingAudioFile = nil
        currentTrack = nextTrack
        anchorDate = Date()
        anchorOffset = 0
        pausedProgress = 0
        progress = 0
        isCrossfading = false
        crossfadeScheduled = false
        updateNowPlayingInfo()
    }

    private func cancelCrossfade() {
        guard isCrossfading else { return }
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeStartTime = nil
        let idle = (activePlayer === playerA) ? playerB : playerA
        idle.stop()
        idle.volume = 0
        activePlayer.volume = 1.0
        incomingAudioFile = nil
        isCrossfading = false
        crossfadeScheduled = false
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
        guard isPlaying else { return }
        progress = liveProgress()
        scheduleCrossfadeIfNeeded()
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
