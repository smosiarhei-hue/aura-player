import AVFoundation
import Combine
import Foundation

@MainActor
final class PlayerCore: ObservableObject {
    static let shared = PlayerCore()
    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // MARK: - Published state
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var progress: Double = 0
    @Published private(set) var playError: String?
    @Published var queue: [Track] = []
    @Published var shuffle: Bool = false { didSet { defaults.set(shuffle, forKey: "player.shuffle") } }
    @Published var repeatMode: RepeatMode = .off { didSet { defaults.set(repeatMode.rawValue, forKey: "player.repeat") } }
    @Published var eqEnabled: Bool = true { didSet { applyEQ(); defaults.set(eqEnabled, forKey: "eq.enabled") } }
    @Published var eqGains: [Float] = EQPresets.flat.gains { didSet { applyEQ(); saveEQ() } }
    @Published var automixEnabled: Bool = true { didSet { defaults.set(automixEnabled, forKey: "player.automix") } }

    private let defaults = UserDefaults.standard
    private let engine = AVAudioEngine()

    // Dual players for crossfade
    private let outgoingPlayer = AVAudioPlayerNode()
    private let incomingPlayer = AVAudioPlayerNode()
    private var activePlayerRef: AVAudioPlayerNode  // points to the currently-heard player

    private let eqNode = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)

    private var file: AVAudioFile?
    private var incomingFile: AVAudioFile?
    private var generation = 0
    private var anchorDate: Date?
    private var anchorOffset: Double = 0
    private var pausedProgress: Double = 0
    private var needsReschedule = false
    private var progressTimer: Timer?

    // Automix / crossfade state
    private var isCrossfading = false
    private var crossfadeScheduled = false
    private let crossfadeDuration: Double = 2.0
    private var crossfadeStartTime: Date?
    private var crossfadeTimer: Timer?
    // Streaming support
    private var streamURL: URL?
    private var streamFile: AVAudioFile?

    var duration: Double { max(currentTrack?.duration ?? 0, 0.001) }

    // MARK: - Init
    private init() {
        activePlayerRef = outgoingPlayer
        configureBands()
        engine.attach(outgoingPlayer)
        engine.attach(incomingPlayer)
        engine.attach(eqNode)
        wire(format: nil)
        configureSession()
        observeInterruptions()
        loadSettings()
        engine.prepare()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    private func configureBands() {
        for (i, band) in eqNode.bands.enumerated() {
            band.frequency = PlayerCore.bandFrequencies[i]
            band.bandwidth = 1.0
            band.bypass = false
            band.gain = 0
        }
    }

    private func wire(format: AVAudioFormat?) {
        engine.disconnectNodeOutput(outgoingPlayer)
        engine.disconnectNodeOutput(incomingPlayer)
        engine.disconnectNodeOutput(eqNode)
        engine.connect(outgoingPlayer, to: eqNode, format: format)
        engine.connect(incomingPlayer, to: eqNode, format: format)
        engine.connect(eqNode, to: engine.mainMixerNode, format: format)
    }

    private func loadSettings() {
        shuffle = defaults.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: defaults.integer(forKey: "player.repeat")) ?? .off
        eqEnabled = defaults.object(forKey: "eq.enabled") as? Bool ?? true
        automixEnabled = defaults.object(forKey: "player.automix") as? Bool ?? true
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

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }

    // MARK: - Player helpers

    private var outgoingVol: Float {
        get { outgoingPlayer.volume }
        set { outgoingPlayer.volume = newValue }
    }
    private var incomingVol: Float {
        get { incomingPlayer.volume }
        set { incomingPlayer.volume = newValue }
    }
    private var activeVolume: Float {
        get { activePlayerRef.volume }
        set { activePlayerRef.volume = newValue }
    }

    /// The player node currently producing audible output.
    private var activeNode: AVAudioPlayerNode { activePlayerRef }
    /// The idle player node (used as the next crossfade target).
    private var idleNode: AVAudioPlayerNode {
        activePlayerRef === outgoingPlayer ? incomingPlayer : outgoingPlayer
    }

    private func swapPlayers() {
        activePlayerRef = (activePlayerRef === outgoingPlayer) ? incomingPlayer : outgoingPlayer
    }

    // MARK: - Jamendo / URL streaming

    func playJamendoStream(_ track: Track, streamURL: URL) {
        queue = []
        currentTrack = track
        playError = nil
        streamURL = streamURL
        startStream(at: 0)
    }

    private func startStream(at seconds: Double) {
        guard let track = currentTrack, let url = streamURL else { return }
        generation += 1
        let token = generation
        cancelCrossfade()
        outgoingPlayer.stop()
        incomingPlayer.stop()
        outgoingVol = 1.0
        incomingVol = 0.0
        activePlayerRef = outgoingPlayer

        // Download to temp, then play
        Task {
            do {
                let (tmpUrl, _) = try await URLSession.shared.download(from: url)
                let audioFile = try AVAudioFile(forReading: tmpUrl)
                self.streamFile = audioFile
                await MainActor.run {
                    guard self.generation == token else { return }
                    self.file = audioFile
                    self.engine.stop()
                    self.wire(format: audioFile.processingFormat)
                    try? self.engine.start()
                    if seconds > 0 {
                        let sr = audioFile.processingFormat.sampleRate
                        let offsetFrames = AVAudioFramePosition(seconds * sr)
                        audioFile.framePosition = max(0, min(offsetFrames, audioFile.length - 1))
                    }
                    self.outgoingPlayer.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        DispatchQueue.main.async {
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.isPlaying = false
                                self.progress = self.duration
                                self.anchorDate = nil
                            }
                        }
                    }
                    self.outgoingPlayer.play()
                    self.isPlaying = true
                    self.anchorDate = Date()
                    self.anchorOffset = seconds
                    self.pausedProgress = seconds
                    self.progress = seconds
                    self.startTimer()
                }
            } catch {
                await MainActor.run {
                    self.file = nil
                    self.isPlaying = false
                    self.playError = "Ошибка стриминга: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Public controls

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
        crossfadeScheduled = false
        isCrossfading = false
        start(at: 0)
    }

    func pause() {
        guard isPlaying else { return }
        pausedProgress = liveProgress()
        activeNode.pause()
        isPlaying = false
        anchorDate = nil
        progress = pausedProgress
    }

    func resume() {
        guard !isPlaying, currentTrack != nil else { return }
        if file == nil || needsReschedule {
            start(at: pausedProgress)
            needsReschedule = false
            return
        }
        if !engine.isRunning { try? engine.start() }
        activeNode.play()
        isPlaying = true
        anchorDate = Date()
        anchorOffset = pausedProgress
        startTimer()
    }

    func next() {
        cancelCrossfade()
        if let n = peekNext(auto: false) {
            currentTrack = n
            start(at: 0)
        } else if let cur = currentTrack {
            start(at: 0)
            currentTrack = cur
        }
    }

    func previous() {
        cancelCrossfade()
        let p = liveProgress()
        if p > 3 { seek(to: 0); return }
        let q = effectiveQueue()
        guard let cur = currentTrack,
              let idx = q.firstIndex(where: { $0.id == cur.id }),
              idx > 0 else { seek(to: 0); return }
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
            needsReschedule = true
        }
    }

    func stopAndClear() {
        generation += 1
        outgoingPlayer.stop()
        incomingPlayer.stop()
        file = nil
        incomingFile = nil
        currentTrack = nil
        isPlaying = false
        progress = 0
        pausedProgress = 0
        anchorDate = nil
        crossfadeScheduled = false
        isCrossfading = false
        SpectrumAnalyzer.shared.reset()
    }

    // MARK: - Internal playback

    private func start(at seconds: Double) {
        guard let track = currentTrack else { return }
        // If this is a stream track, use streaming path
        if streamURL != nil && !FileManager.default.fileExists(atPath: track.url.path) {
            startStream(at: seconds)
            return
        }
        generation += 1
        let token = generation

        // Stop both players, reset volumes
        outgoingPlayer.stop()
        incomingPlayer.stop()
        outgoingVol = 1.0
        incomingVol = 0.0
        activePlayerRef = outgoingPlayer
        isCrossfading = false
        crossfadeScheduled = false
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeStartTime = nil

        do {
            let audioFile = try AVAudioFile(forReading: track.url)
            file = audioFile
            incomingFile = nil
            engine.stop()
            wire(format: audioFile.processingFormat)
            try engine.start()
            let sr = audioFile.processingFormat.sampleRate
            let offsetFrames = AVAudioFramePosition(seconds * sr)
            audioFile.framePosition = max(0, min(offsetFrames, audioFile.length - 1))
            outgoingPlayer.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.handleFinish()
                    }
                }
            }
            outgoingPlayer.play()
            isPlaying = true
            anchorDate = Date()
            anchorOffset = seconds
            pausedProgress = seconds
            progress = seconds
            startTimer()
        } catch {
            file = nil
            isPlaying = false
            playError = "Не удалось открыть: \(track.fileName)"
        }
    }

    // MARK: - Automix / Crossfade

    /// Called from tickProgress() when the track is near its end.
    private func scheduleCrossfadeIfNeeded() {
        guard automixEnabled, !isCrossfading, !crossfadeScheduled, isPlaying else { return }
        let remaining = duration - liveProgress()
        guard remaining <= crossfadeDuration, remaining > 0 else { return }
        guard let nextTrack = peekNext(auto: true) else { return }
        crossfadeScheduled = true
        isCrossfading = true

        let idle = idleNode
        let token = generation

        do {
            let nextFile = try AVAudioFile(forReading: nextTrack.url)
            incomingFile = nextFile

            // Reconnect idle node with new file's format if needed
            if idle.outputFormat(forBus: 0) != nextFile.processingFormat {
                engine.disconnectNodeOutput(idle)
                engine.connect(idle, to: eqNode, format: nextFile.processingFormat)
            }

            idle.scheduleFile(nextFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.completeCrossfade(to: nextTrack)
                    }
                }
            }

            // Start incoming at volume 0
            idle.volume = 0
            if !engine.isRunning { try? engine.start() }
            idle.play()

            // Manual crossfade via timer
            crossfadeStartTime = Date()
            startCrossfadeTimer()

        } catch {
            isCrossfading = false
            crossfadeScheduled = false
        }
    }

    /// Called when the incoming player finishes playing (crossfade complete).
    private func completeCrossfade(to nextTrack: Track) {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeStartTime = nil

        let oldActive = activeNode
        oldActive.stop()
        oldActive.volume = 1

        // Swap: the incoming becomes the new active
        swapPlayers()
        file = incomingFile
        incomingFile = nil
        currentTrack = nextTrack
        anchorDate = Date()
        anchorOffset = 0
        pausedProgress = 0
        progress = 0
        isCrossfading = false
        crossfadeScheduled = false
    }

    private func cancelCrossfade() {
        guard isCrossfading else { return }
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeStartTime = nil
        let idle = idleNode
        idle.stop()
        idle.volume = 0
        activeNode.volume = 1
        incomingFile = nil
        isCrossfading = false
        crossfadeScheduled = false
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
        let progress = min(elapsed / crossfadeDuration, 1.0)
        let outVol = Float(1.0 - progress)
        let inVol = Float(progress)
        activeNode.volume = outVol
        idleNode.volume = inVol
    }

    // MARK: - Track finish (non-crossfade path)

    private func handleFinish() {
        progress = duration
        anchorDate = nil
        isPlaying = false
        if repeatMode == .one { start(at: 0); return }
        if let next = peekNext(auto: true) {
            currentTrack = next
            start(at: 0)
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
            var candidates = q.filter { $0.id != currentTrack?.id }
            return candidates.randomElement()
        }
        guard let cur = currentTrack, let idx = q.firstIndex(where: { $0.id == cur.id }) else { return q.first }
        let nextIdx = idx + 1
        if nextIdx < q.count { return q[nextIdx] }
        if repeatMode == .all { return q.first }
        return auto ? nil : q.first
    }

    // MARK: - Progress

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

    // MARK: - Helpers

    func formatted(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Spectrum tap

    func installSpectrumTap() {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            SpectrumAnalyzer.shared.process(buffer: buffer, sampleRate: buffer.format.sampleRate)
        }
    }
}
