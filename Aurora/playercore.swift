import AVFoundation
import Combine
import Foundation

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

    private let defaults = UserDefaults.standard
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)

    private var file: AVAudioFile?
    private var generation = 0
    private var anchorDate: Date?
    private var anchorOffset: Double = 0
    private var pausedProgress: Double = 0
    private var needsReschedule = false
    private var progressTimer: Timer?

    var duration: Double { max(currentTrack?.duration ?? 0, 0.001) }

    // MARK: - Init
    private init() {
        configureBands()
        engine.attach(player)
        engine.attach(eqNode)
        wire(fileFormat: nil)
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

    private func wire(fileFormat: AVAudioFormat?) {
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(eqNode)
        engine.connect(player, to: eqNode, format: fileFormat)
        engine.connect(eqNode, to: engine.mainMixerNode, format: fileFormat)
    }

    private func loadSettings() {
        shuffle = defaults.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: defaults.integer(forKey: "player.repeat")) ?? .off
        eqEnabled = defaults.object(forKey: "eq.enabled") as? Bool ?? true
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
        start(at: 0)
    }

    func pause() {
        guard isPlaying else { return }
        pausedProgress = liveProgress()
        player.pause()
        isPlaying = false
        anchorDate = nil
        progress = pausedProgress
    }

    func resume() {
        guard !isPlaying, currentTrack != nil else { return }
        if file == nil || needsReschedule { start(at: pausedProgress); needsReschedule = false; return }
        if !engine.isRunning { try? engine.start() }
        player.play()
        isPlaying = true
        anchorDate = Date()
        anchorOffset = pausedProgress
        startTimer()
    }

    func next() {
        if let n = peekNext(auto: false) { currentTrack = n; start(at: 0) }
        else if let cur = currentTrack { start(at: 0); currentTrack = cur }
    }

    func previous() {
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
        player.stop()
        file = nil
        currentTrack = nil
        isPlaying = false
        progress = 0
        pausedProgress = 0
        anchorDate = nil
        SpectrumAnalyzer.shared.reset()
    }

    // MARK: - Internal playback

    private func start(at seconds: Double) {
        guard let track = currentTrack else { return }
        generation += 1
        let token = generation
        player.stop()
        do {
            let audioFile = try AVAudioFile(forReading: track.url)
            file = audioFile
            engine.stop()
            wire(fileFormat: audioFile.processingFormat)
            try engine.start()
            let sr = audioFile.processingFormat.sampleRate
            let offsetFrames = AVAudioFramePosition(seconds * sr)
            audioFile.framePosition = max(0, min(offsetFrames, audioFile.length - 1))
            player.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.handleFinish()
                    }
                }
            }
            player.play()
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

    private func handleFinish() {
        progress = duration
        anchorDate = nil
        isPlaying = false
        if repeatMode == .one { start(at: 0); return }
        if let next = peekNext(auto: true) { currentTrack = next; start(at: 0) }
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
