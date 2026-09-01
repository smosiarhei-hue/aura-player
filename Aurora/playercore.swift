@preconcurrency import AVFoundation
import CoreMedia
import MediaPlayer
import SwiftUI
import UIKit
import Observation

// MARK: - Audio Quality Selection

enum AudioQuality: Int, CaseIterable, Identifiable, Sendable {
    case hiResLossless = 0
    case lossless = 1
    case hq = 2
    case auto = 3
    case economical = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .hiResLossless: return "Hi-Res Lossless (FLAC 24-bit)"
        case .lossless: return "Lossless (FLAC 16-bit / 44.1 kHz)"
        case .hq: return "Высокое качество (AAC / MP3 320 kbps)"
        case .auto: return "Автоматически (По скорости сети)"
        case .economical: return "Экономия трафика (64-128 kbps)"
        }
    }

    var badgeText: String {
        switch self {
        case .hiResLossless: return "Hi-Res Lossless"
        case .lossless: return "Lossless"
        case .hq: return "HQ"
        case .auto: return "Lossless"
        case .economical: return "AAC"
        }
    }

    var detail: String {
        switch self {
        case .hiResLossless: return "Студийное качество без потерь (FLAC 24-бит) для аудиофилов и внешних ЦАП"
        case .lossless: return "Качество компакт-диска (CD) без сжатия до 1411 кбит/с (FLAC 16-бит / 44.1 кГц)"
        case .hq: return "Кристально чистый звук в максимальном битрейте 320 кбит/с"
        case .auto: return "Автоматический выбор наилучшего доступного качества под скорость сети"
        case .economical: return "Минимальный расход мобильного интернета (64-128 кбит/с)"
        }
    }

    var targetBitrate: Int? {
        switch self {
        case .hiResLossless: return 1411
        case .lossless: return 900
        case .hq: return 320
        case .auto: return nil
        case .economical: return 64
        }
    }
}

// MARK: - Fast Progressive Audio & Local Playback Engine (PlayerCore)

@Observable
@MainActor
final class PlayerCore {
    static let shared = PlayerCore()
    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // MARK: - Published state
    private(set) var isPlaying = false
    private(set) var currentTrack: Track?
    private(set) var progress: Double = 0
    private(set) var streamDuration: Double = 0
    private(set) var playError: String?
    var volume: Float = 1.0 {
        didSet {
            streamingPlayer.volume = volume
            engine.mainMixerNode.outputVolume = volume
            defaults.set(volume, forKey: "player.volume")
        }
    }
    var queue: [Track] = []
    var shuffle: Bool = false { didSet { defaults.set(shuffle, forKey: "player.shuffle") } }
    var repeatMode: RepeatMode = .off { didSet { defaults.set(repeatMode.rawValue, forKey: "player.repeat") } }
    var eqEnabled: Bool = true { didSet { applyEQ(); defaults.set(eqEnabled, forKey: "eq.enabled") } }
    var eqGains: [Float] = EQPresets.flat.gains { didSet { applyEQ(); saveEQ() } }

    // Transition Settings
    var transitionMode: TransitionMode = .automix { didSet { defaults.set(transitionMode.rawValue, forKey: "player.transitionMode") } }
    var crossfadeDuration: Double = 3.0 { didSet { defaults.set(crossfadeDuration, forKey: "player.crossfadeDuration") } }

    // Audio Quality
    private(set) var currentBitrate: Int?
    private(set) var currentCodec: String?
    var audioQuality: AudioQuality = .auto { didSet { defaults.set(audioQuality.rawValue, forKey: "player.quality") } }

    // Sleep Timer
    private(set) var sleepTimerMinutes: Int? = nil
    private(set) var sleepTimerRemaining: Double? = nil
    private var sleepTimer: Timer?
    private var sleepDeadline: Date?

    private let defaults = UserDefaults.standard

    // Instant Streaming Engine (Dual AVPlayers for Seamless DJ Transitions & Pre-buffering)
    private let streamingPlayerA = AVPlayer()
    private let streamingPlayerB = AVPlayer()
    private var activeStreamingPlayer: AVPlayer
    private var idleStreamingPlayer: AVPlayer
    var streamingPlayer: AVPlayer { activeStreamingPlayer }
    private var isUsingStreamPlayer = false
    private var isPrebufferingNextStream = false
    private var prebufferedTrackId: UUID? = nil

    // Local Audio Engine (AVAudioEngine + TimePitch + 10-band EQ + Reverb)
    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private var activePlayer: AVAudioPlayerNode
    private let eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let timePitchA = AVAudioUnitTimePitch()
    private let timePitchB = AVAudioUnitTimePitch()
    private let reverbA = AVAudioUnitReverb()
    private let reverbB = AVAudioUnitReverb()

    private var activeAudioFile: AVAudioFile?
    private var incomingAudioFile: AVAudioFile?
    private var incomingTrack: Track?
    private var generation = 0
    private var anchorDate: Date?
    private var anchorOffset: Double = 0
    private var pausedProgress: Double = 0
    private var progressTimer: Timer?

    // Remote artwork cache for Now Playing (prevents Control Center flicker)
    private var remoteArtworkCache: [UUID: UIImage] = [:]
    // Throttle for lock screen / Control Center elapsed-time refresh
    private var lastNowPlayingSync: Date?

    // AutoMix State
    private var isTransitioning = false
    private var transitionScheduled = false
    private var transitionStartTime: Date?
    private var transitionDuration: Double = 3.0
    private var transitionTimer: Timer?
    private var currentAutoMixStyle: AutoMixStyle = .bassSwapBlend(duration: 3.5)
    private let transitionTick: TimeInterval = 1.0 / 60.0

    // AutoMix planning (offline first, AI refinement only when it arrives in time)
    private var activeTransitionPlan: TransitionPlan? = nil
    private var isPlanningTransition = false
    private var analysisCache: [UUID: TrackAnalysis] = [:]
    private var analysisRequested: Set<UUID> = []
    private var aiRefinementRequested: Set<String> = []

    // Tempo release after a beat-matched blend (CDJ style ramp back to 1.0)
    private var incomingTempoRate: Float = 1.0
    private var outgoingTempoRate: Float = 1.0
    private var rateReleaseTimer: Timer?
    private var rateReleaseStart: Date?
    private var rateReleaseFrom: Float = 1.0
    private let rateReleaseDuration: TimeInterval = 8.0
    private let rateReleaseTick: TimeInterval = 1.0 / 30.0

    var duration: Double {
        if isUsingStreamPlayer {
            if streamDuration > 0 { return streamDuration }
            if let item = activeStreamingPlayer.currentItem {
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
        activeStreamingPlayer = streamingPlayerA
        idleStreamingPlayer = streamingPlayerB
        configureSession()
        setupAudioEngine()
        setupStreamingPlayer()
        loadSettings()
        setupRemoteCommandCenter()
        // Required for the system to route lock screen / Control Center events here.
        UIApplication.shared.beginReceivingRemoteControlEvents()
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
        for p in [streamingPlayerA, streamingPlayerB] {
            p.automaticallyWaitsToMinimizeStalling = false
            p.volume = volume

            let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
            p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, self.isUsingStreamPlayer, self.isPlaying, p === self.activeStreamingPlayer else { return }
                    let sec = CMTimeGetSeconds(time)
                    if sec.isFinite && sec >= 0 {
                        self.progress = sec

                        if let item = self.activeStreamingPlayer.currentItem {
                            let d = CMTimeGetSeconds(item.duration)
                            if d.isFinite && d > 0 && self.streamDuration != d {
                                self.streamDuration = d
                            }
                        }

                        self.syncNowPlayingElapsedIfNeeded()
                        self.scheduleTransitionIfNeeded()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            let finishedItem = notification.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer else { return }
                if let finishedItem, finishedItem !== self.activeStreamingPlayer.currentItem {
                    return
                }
                self.handleTrackFinish()
            }
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            let failedItem = notification.object as? AVPlayerItem
            let message = failedItem?.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer else { return }
                if let failedItem, failedItem !== self.activeStreamingPlayer.currentItem {
                    return
                }
                self.isPlaying = false
                self.playError = message.map { "Ошибка потока: \($0)" } ?? "Не удалось воспроизвести трек"
            }
        }
    }

    private func setupAudioEngine() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(timePitchA)
        engine.attach(timePitchB)
        engine.attach(eqNodeA)
        engine.attach(eqNodeB)
        engine.attach(reverbA)
        engine.attach(reverbB)

        configureEQ(eqNodeA)
        configureEQ(eqNodeB)
        configureTimePitch(timePitchA)
        configureTimePitch(timePitchB)
        configureReverb(reverbA)
        configureReverb(reverbB)

        // Deck A: player -> timePitch -> EQ -> reverb -> mixer
        engine.connect(playerA, to: timePitchA, format: nil)
        engine.connect(timePitchA, to: eqNodeA, format: nil)
        engine.connect(eqNodeA, to: reverbA, format: nil)
        engine.connect(reverbA, to: engine.mainMixerNode, format: nil)

        // Deck B: player -> timePitch -> EQ -> reverb -> mixer
        engine.connect(playerB, to: timePitchB, format: nil)
        engine.connect(timePitchB, to: eqNodeB, format: nil)
        engine.connect(eqNodeB, to: reverbB, format: nil)
        engine.connect(reverbB, to: engine.mainMixerNode, format: nil)

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

    private func configureTimePitch(_ node: AVAudioUnitTimePitch) {
        node.rate = 1.0
        node.pitch = 0
        node.overlap = 8.0
    }

    private func configureReverb(_ node: AVAudioUnitReverb) {
        node.loadFactoryPreset(.largeHall2)
        node.wetDryMix = 0
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

        audioQuality = AudioQuality(rawValue: defaults.integer(forKey: "player.quality")) ?? .auto

        let savedVol = defaults.float(forKey: "player.volume")
        volume = savedVol > 0 ? savedVol : 1.0
        engine.mainMixerNode.outputVolume = volume
        streamingPlayer.volume = volume

        if let data = defaults.data(forKey: "eq.gains"),
           let gains = try? JSONDecoder().decode([Float].self, from: data),
           gains.count == PlayerCore.bandFrequencies.count {
            eqGains = gains
        }
        applyEQ()
        restorePlaybackState()
    }

    func savePlaybackState() {
        guard let track = currentTrack else {
            defaults.removeObject(forKey: "player.lastTrack")
            defaults.removeObject(forKey: "player.lastProgress")
            defaults.removeObject(forKey: "player.lastQueue")
            return
        }
        if let data = try? JSONEncoder().encode(track) {
            defaults.set(data, forKey: "player.lastTrack")
        }
        defaults.set(progress, forKey: "player.lastProgress")
        if !queue.isEmpty, let qData = try? JSONEncoder().encode(Array(queue.prefix(60))) {
            defaults.set(qData, forKey: "player.lastQueue")
        }
    }

    func restorePlaybackState() {
        guard let data = defaults.data(forKey: "player.lastTrack"),
              let track = try? JSONDecoder().decode(Track.self, from: data) else { return }

        currentTrack = track
        let savedProg = defaults.double(forKey: "player.lastProgress")
        progress = max(0, min(savedProg, track.duration > 0 ? track.duration : savedProg))
        pausedProgress = progress
        streamDuration = track.duration

        if let qData = defaults.data(forKey: "player.lastQueue"),
           let savedQueue = try? JSONDecoder().decode([Track].self, from: qData) {
            queue = savedQueue
        }
        updateNowPlayingInfo()
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
    private var activeTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchA : timePitchB }
    private var idleTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchB : timePitchA }
    private var activeReverb: AVAudioUnitReverb { (activePlayer === playerA) ? reverbA : reverbB }
    private var idleReverb: AVAudioUnitReverb { (activePlayer === playerA) ? reverbB : reverbA }

    // MARK: - Lockscreen & Remote Commands

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Standard music-player layout: transport + scrubbing only.
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false
        commandCenter.likeCommand.isEnabled = false
        commandCenter.dislikeCommand.isEnabled = false
        commandCenter.bookmarkCommand.isEnabled = false
        commandCenter.ratingCommand.isEnabled = false

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
            let target = event.positionTime
            Task { @MainActor in self?.seek(to: target) }
            return .success
        }
    }

    // MPMediaItemArtwork calls its request handler on MediaPlayer's
    // background accessQueue, so the handler must not be MainActor-isolated.
    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let data = image.pngData() ?? Data()
        let size = image.size
        return MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(data: data) ?? UIImage()
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()

        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        let elapsed = isUsingStreamPlayer ? progress : liveProgress()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyAlbumArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]

        if let image = LibraryStore.cachedArtworkImage(for: track) {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
        } else if let image = remoteArtworkCache[track.id] {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
        }

        center.nowPlayingInfo = info
        // Declaring the playback state is what makes iOS treat this app as the
        // active Now Playing app, so tapping the title on the lock screen or in
        // Control Center opens it instead of doing nothing.
        center.playbackState = isPlaying ? .playing : .paused
        lastNowPlayingSync = Date()

        // Fetch remote artwork once per track, then cache (prevents flicker)
        if let cover = track.coverURL, let url = URL(string: cover),
           LibraryStore.cachedArtworkImage(for: track) == nil,
           remoteArtworkCache[track.id] == nil {
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else { return }
                guard let self, self.currentTrack?.id == track.id else { return }
                self.remoteArtworkCache[track.id] = image
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }

    /// Keeps the lock screen scrubber honest without rebuilding artwork every frame.
    private func syncNowPlayingElapsedIfNeeded() {
        guard currentTrack != nil else { return }
        let now = Date()
        if let last = lastNowPlayingSync, now.timeIntervalSince(last) < 2.0 { return }
        lastNowPlayingSync = now

        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo, !info.isEmpty else {
            updateNowPlayingInfo()
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = isUsingStreamPlayer ? progress : liveProgress()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = duration
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
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
        savePlaybackState()
    }

    func pause() {
        guard isPlaying else { return }
        if isUsingStreamPlayer {
            activeStreamingPlayer.pause()
            idleStreamingPlayer.pause()
        } else {
            pausedProgress = liveProgress()
            activePlayer.pause()
            anchorDate = nil
            progress = pausedProgress
        }
        isPlaying = false
        updateNowPlayingInfo()
        savePlaybackState()
    }

    func resume() {
        guard !isPlaying, let track = currentTrack else { return }
        if track.isStream || track.streamUrlString != nil {
            if activeStreamingPlayer.currentItem == nil {
                start(at: progress)
                return
            }
            activeStreamingPlayer.play()
            if isTransitioning {
                idleStreamingPlayer.play()
            }
            isPlaying = true
        } else {
            if activeAudioFile == nil {
                start(at: progress > 0 ? progress : pausedProgress)
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
        savePlaybackState()
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
            activeStreamingPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        } else {
            pausedProgress = clamped
            anchorOffset = clamped
            if isPlaying {
                start(at: clamped)
            }
        }
        lastNowPlayingSync = nil
        updateNowPlayingInfo()
    }

    func stopAndClear() {
        cancelSleepTimer()
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

    // MARK: - Internal Playback Helpers

    private func start(at seconds: Double) {
        guard let track = currentTrack else { return }
        playError = nil
        generation += 1
        let token = generation
        activeTransitionPlan = nil
        isPlanningTransition = false

        // Analysis takes seconds, so it starts the moment a track starts playing.
        prewarmAnalysis(for: track)
        if let upcoming = peekNext(auto: true) { prewarmAnalysis(for: upcoming) }

        if track.isStream || track.streamUrlString != nil {
            startStream(track, at: seconds, token: token)
        } else {
            startLocal(track, at: seconds, token: token)
        }
    }

    private func startLocal(_ track: Track, at seconds: Double, token: Int) {
        isUsingStreamPlayer = false
        activeStreamingPlayer.pause()
        idleStreamingPlayer.pause()
        playerA.stop()
        playerB.stop()
        playerA.volume = 1.0
        playerB.volume = 0.0
        activePlayer = playerA
        stopRateRelease()
        timePitchA.rate = 1.0
        timePitchB.rate = 1.0
        reverbA.wetDryMix = 0
        reverbB.wetDryMix = 0
        incomingTempoRate = 1.0
        outgoingTempoRate = 1.0
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
                    Task { @MainActor in
                        guard let self, self.generation == token, !self.isUsingStreamPlayer else { return }
                        self.handleTrackFinish()
                    }
                }

                self.playerA.play()
                self.isPlaying = true
                self.anchorDate = Date()
                self.anchorOffset = seconds
                self.pausedProgress = seconds
                self.progress = seconds
                self.startTimer()
                self.lastNowPlayingSync = nil
                self.updateNowPlayingInfo()
            } catch {
                self.activeAudioFile = nil
                self.isPlaying = false
                self.playError = "Не удалось открыть аудио: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Stream Resolution (direct URL vs Yandex on-demand id)

    private func startStream(_ track: Track, at seconds: Double, token: Int) {
        isUsingStreamPlayer = true
        playerA.stop()
        playerB.stop()

        let url = track.url
        // Resolved direct stream URL; unresolved Yandex tracks keep only the track id.
        if url.scheme == "http" || url.scheme == "https" {
            currentBitrate = 128   // fallback for direct URL streams
            currentCodec = "mp3"
            beginStream(url, at: seconds)
            return
        }

        let ymID = Self.yandexTrackID(from: track)
        Task {
            do {
                let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                guard self.generation == token, self.currentTrack?.id == track.id else { return }
                self.currentBitrate = info.bitrate
                self.currentCodec = info.codec
                self.beginStream(info.url, at: seconds)
            } catch {
                guard self.generation == token else { return }
                self.isPlaying = false
                self.transitionScheduled = false
                self.playError = "Не удалось открыть поток трека"
            }
        }
    }

    static func yandexTrackID(from track: Track) -> String {
        let raw = track.streamUrlString ?? ""
        return raw
            .replacingOccurrences(of: "ym_", with: "")
            .replacingOccurrences(of: ".mp3", with: "")
    }

    func selectQuality(_ q: AudioQuality) {
        guard q != audioQuality else { return }
        audioQuality = q
        reapplyStreamQuality()
    }

    private func reapplyStreamQuality() {
        guard let track = currentTrack, track.isStream else { return }
        let url = track.url
        guard !(url.scheme == "http" || url.scheme == "https") else { return } // direct URL, no-op
        let ymID = Self.yandexTrackID(from: track)
        let pos = progress
        let token = generation
        Task {
            do {
                let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                guard self.generation == token, self.currentTrack?.id == track.id else { return }
                self.currentBitrate = info.bitrate
                self.currentCodec = info.codec
                self.beginStream(info.url, at: pos)
            } catch { }
        }
    }

    private func beginStream(_ url: URL, at seconds: Double) {
        let item = AVPlayerItem(url: url)
        StreamBeatTap.shared.attach(to: item)
        activeStreamingPlayer.replaceCurrentItem(with: item)
        activeStreamingPlayer.volume = volume
        if seconds > 0 {
            activeStreamingPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        activeStreamingPlayer.play()
        self.isPlaying = true
        self.progress = seconds
        self.transitionScheduled = false
        self.lastNowPlayingSync = nil
        self.updateNowPlayingInfo()
    }

    // MARK: - Track Analysis (real BPM, key, downbeats — never guessed)

    private func prewarmAnalysis(for track: Track) {
        guard !track.isStream, track.url.isFileURL else { return }
        guard analysisCache[track.id] == nil, !analysisRequested.contains(track.id) else { return }
        analysisRequested.insert(track.id)
        let id = track.id
        let url = track.url
        Task { [weak self] in
            let result = await TrackAnalysisService.shared.analysis(trackID: id, url: url)
            guard let self else { return }
            self.analysisRequested.remove(id)
            guard let result else { return }
            self.analysisCache[id] = result
            if let bpm = result.bpm, self.currentTrack?.id == id {
                AutoMixDJEngine.shared.currentBPM = bpm
            }
            SonivoDiagnostics.log("[AutoMix] Analysed \(url.lastPathComponent): BPM \(String(format: "%.1f", result.bpm ?? 0)), key \(result.musicalKey ?? "?"), downbeats \(result.downbeats.count)", tag: "AUTOMIX")
        }
    }

    // MARK: - AutoMix DJ Transitions (offline DSP first, AI refinement when it arrives in time)

    private func scheduleTransitionIfNeeded() {
        guard transitionMode != .off, !isTransitioning, !transitionScheduled, isPlaying, let current = currentTrack else { return }
        let currentPos = isUsingStreamPlayer ? progress : liveProgress()
        let totalDur = duration
        guard totalDur > 10, let nextTrack = peekNext(auto: true) else { return }

        let remaining = totalDur - currentPos

        if remaining <= 120 {
            prewarmAnalysis(for: current)
            prewarmAnalysis(for: nextTrack)
        }

        // 1. Offline plan — instant, no network, built from the real analysis.
        if activeTransitionPlan == nil, remaining <= 60 {
            activeTransitionPlan = buildPlan(current: current, currentDuration: totalDur, next: nextTrack)
        }

        // 2. Optional AI refinement — requested early, applied only if it returns before the cue.
        if transitionMode == .automix, remaining <= 55 {
            requestAIRefinement(current: current, next: nextTrack, position: currentPos)
        }

        // 3. Pre-buffer the incoming stream well ahead of the cue.
        let leadTime = activeTransitionPlan?.leadTime ?? 18.0
        let prebufferThreshold = leadTime + 14.0
        if (isUsingStreamPlayer || nextTrack.isStream) && remaining <= prebufferThreshold && prebufferedTrackId != nextTrack.id && !isPrebufferingNextStream {
            isPrebufferingNextStream = true
            let ymID = Self.yandexTrackID(from: nextTrack)
            Task {
                do {
                    let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                    let nextItem = AVPlayerItem(url: info.url)
                    StreamBeatTap.shared.attach(to: nextItem)
                    self.idleStreamingPlayer.replaceCurrentItem(with: nextItem)
                    self.idleStreamingPlayer.volume = 0
                    self.idleStreamingPlayer.pause()
                    self.prebufferedTrackId = nextTrack.id
                    self.isPrebufferingNextStream = false
                    SonivoDiagnostics.log("[AutoMix] Pre-buffered upcoming stream: \(nextTrack.title)", tag: "AUTOMIX")
                } catch {
                    self.isPrebufferingNextStream = false
                }
            }
        }

        guard let plan = activeTransitionPlan else { return }
        guard currentPos >= plan.cueTime, (totalDur - currentPos) > 0.05 else { return }

        beginTransition(plan: plan, to: nextTrack)
    }

    /// Offline decision. Uses the real analysis when it is ready and degrades to an
    /// honest short crossfade when it is not — never to invented tempo values.
    private func buildPlan(current: Track, currentDuration: Double, next: Track) -> TransitionPlan {
        switch transitionMode {
        case .off:
            return neutralPlan(duration: currentDuration, blend: 0.05, strategy: .HARD_CUT, reason: "Переходы выключены")
        case .gapless:
            return neutralPlan(duration: currentDuration, blend: 0.12, strategy: .HARD_CUT, reason: "Gapless: без паузы между треками")
        case .crossfade:
            let blend = max(1.0, crossfadeDuration)
            return neutralPlan(duration: currentDuration, blend: blend, strategy: .SIMPLE_CROSSFADE, reason: "Кроссфейд \(Int(blend)) с")
        case .automix:
            guard let source = analysisCache[current.id], let target = analysisCache[next.id] else {
                return neutralPlan(duration: currentDuration, blend: 6.0, strategy: .SIMPLE_CROSSFADE, reason: "Анализ трека ещё не готов — мягкий кроссфейд")
            }
            let plan = TransitionPlanner.planLocalFallback(
                sourceTrack: current,
                sourceAnalysis: source,
                targetTrack: next,
                targetAnalysis: target
            )
            return snappedToDownbeat(plan, analysis: source)
        }
    }

    private func neutralPlan(duration: Double, blend: Double, strategy: TransitionStrategy, reason: String) -> TransitionPlan {
        let cue = max(0, duration - blend)
        return TransitionPlan(
            decision: TransitionDecisionInfo(transitionType: strategy.rawValue, confidence: 0.5, reason: reason),
            sourceTrack: TransitionSourceTrackInfo(transitionStart: cue, transitionEnd: duration),
            targetTrack: TransitionTargetTrackInfo(startPosition: 0),
            tempo: TransitionTempoInfo(targetBPM: 0, sourcePlaybackRate: 1.0, targetPlaybackRate: 1.0),
            actions: [],
            fallback: TransitionFallbackInfo(type: TransitionStrategy.SIMPLE_CROSSFADE.rawValue)
        )
    }

    /// The mix must land on a downbeat, otherwise it never feels in time.
    private func snappedToDownbeat(_ plan: TransitionPlan, analysis: TrackAnalysis) -> TransitionPlan {
        guard analysis.hasSteadyBeat,
              let downbeat = analysis.nearestDownbeat(to: plan.cueTime, tolerance: 4.0) else { return plan }
        return TransitionPlan(
            decision: plan.decision,
            sourceTrack: TransitionSourceTrackInfo(transitionStart: downbeat, transitionEnd: plan.sourceTrack.transitionEnd),
            targetTrack: plan.targetTrack,
            tempo: plan.tempo,
            actions: plan.actions,
            fallback: plan.fallback
        )
    }

    private func requestAIRefinement(current: Track, next: Track, position: Double) {
        guard let source = analysisCache[current.id], let target = analysisCache[next.id] else { return }
        let key = current.id.uuidString + "->" + next.id.uuidString
        guard !aiRefinementRequested.contains(key) else { return }
        aiRefinementRequested.insert(key)

        Task { [weak self] in
            let plan = await GeminiAutoMixPlanner.shared.planTransition(
                sourceTrack: current,
                sourceAnalysis: source,
                targetTrack: next,
                targetAnalysis: target,
                currentPosition: position
            )
            guard let self else { return }
            // Only adopt the AI plan while the offline one has not fired yet.
            guard !self.isTransitioning, !self.transitionScheduled,
                  self.currentTrack?.id == current.id else { return }
            let livePosition = self.isUsingStreamPlayer ? self.progress : self.liveProgress()
            guard plan.cueTime > livePosition + 1.0 else { return }
            self.activeTransitionPlan = self.snappedToDownbeat(plan, analysis: source)
            SonivoDiagnostics.log("[AutoMix AI] Plan adopted: \(plan.decision.transitionType) at \(String(format: "%.1f", plan.cueTime))s", tag: "AUTOMIX")
        }
    }

    private func beginTransition(plan: TransitionPlan, to nextTrack: Track) {
        transitionScheduled = true
        isTransitioning = true
        transitionDuration = max(0.1, plan.leadTime)
        incomingTrack = nextTrack
        currentAutoMixStyle = .bassSwapBlend(duration: transitionDuration)

        let strategy = plan.strategy
        outgoingTempoRate = Float(min(1.08, max(0.92, plan.tempo.sourcePlaybackRate)))
        incomingTempoRate = Float(min(1.08, max(0.92, plan.tempo.targetPlaybackRate)))

        AutoMixDJEngine.shared.isTransitionActive = true
        AutoMixDJEngine.shared.activeStrategyName = strategy.rawValue
        AutoMixDJEngine.shared.activePlan = plan
        AutoMixDJEngine.shared.statusBadge = "AutoMix"

        SonivoDiagnostics.log("[AutoMix] Transition: \(currentTrack?.title ?? "?") -> \(nextTrack.title) [\(strategy.rawValue), \(String(format: "%.1f", transitionDuration))s, rate in \(String(format: "%.3f", incomingTempoRate)), \(plan.decision.reason)]", tag: "AUTOMIX")

        if isUsingStreamPlayer || nextTrack.isStream {
            if idleStreamingPlayer.currentItem == nil || prebufferedTrackId != nextTrack.id {
                let ymID = Self.yandexTrackID(from: nextTrack)
                Task {
                    do {
                        let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                        let nextItem = AVPlayerItem(url: info.url)
                        StreamBeatTap.shared.attach(to: nextItem)
                        self.idleStreamingPlayer.replaceCurrentItem(with: nextItem)
                        self.idleStreamingPlayer.volume = 0.05
                        self.idleStreamingPlayer.seek(to: CMTime(seconds: plan.targetTrack.startPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                        self.idleStreamingPlayer.playImmediately(atRate: self.incomingTempoRate)
                        self.transitionStartTime = Date()
                        self.startTransitionTimer()
                    } catch {
                        self.isTransitioning = false
                        self.transitionScheduled = false
                        AutoMixDJEngine.shared.isTransitionActive = false
                        AutoMixDJEngine.shared.statusBadge = nil
                        SonivoDiagnostics.log("[AutoMix] Stream fetch failed: \(error.localizedDescription)", tag: "AUTOMIX")
                    }
                }
            } else {
                idleStreamingPlayer.volume = 0.05
                idleStreamingPlayer.seek(to: CMTime(seconds: plan.targetTrack.startPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                idleStreamingPlayer.playImmediately(atRate: incomingTempoRate)
                transitionStartTime = Date()
                startTransitionTimer()
            }
            return
        }

        // Local multi-node AVAudioEngine AutoMix: tempo sync + EQ swap + reverb
        let targetIdlePlayer = idlePlayer
        let targetIdleTimePitch = idleTimePitch
        let targetIsPlayerA = targetIdlePlayer === playerA
        let startPosition = max(0, plan.targetTrack.startPosition)
        let rate = incomingTempoRate

        Task {
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile

                let sr = nextFile.processingFormat.sampleRate
                let startFrame = max(0, min(AVAudioFramePosition(startPosition * sr), max(0, nextFile.length - 1)))
                let frameCount = AVAudioFrameCount(nextFile.length - startFrame)

                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: startFrame, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self,
                              self.activePlayer === (targetIsPlayerA ? self.playerA : self.playerB) else { return }
                        self.handleTrackFinish()
                    }
                }

                targetIdlePlayer.volume = 0
                targetIdleTimePitch.rate = rate
                if !self.engine.isRunning { try? self.engine.start() }
                targetIdlePlayer.play()

                self.transitionStartTime = Date()
                self.startTransitionTimer()
            } catch {
                self.isTransitioning = false
                self.transitionScheduled = false
                AutoMixDJEngine.shared.isTransitionActive = false
                AutoMixDJEngine.shared.statusBadge = nil
            }
        }
    }

    private func startTransitionTimer() {
        transitionTimer?.invalidate()
        let t = Timer(timeInterval: transitionTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTransition() }
        }
        RunLoop.main.add(t, forMode: .common)
        transitionTimer = t
    }

    // MARK: - Transition automation (volume, bass swap, high cut, reverb, tempo)

    private struct TransitionFX: Sendable {
        var outVolume: Float
        var inVolume: Float
        var outBassDB: Float
        var inBassDB: Float
        var outHighDB: Float
        var inHighDB: Float
        var outReverb: Float
        var inReverb: Float
    }

    private func automation(progress: Double, strategy: TransitionStrategy) -> TransitionFX {
        let p = Float(max(0, min(1, progress)))
        // Equal-power base curve keeps perceived loudness constant.
        let outVol = cos(p * .pi / 2)
        let inVol = sin(p * .pi / 2)

        switch strategy {
        case .BASS_SWAP, .BEAT_MATCH, .BEAT_MATCH_EQ:
            let handOver = min(1, p / 0.55)
            let received = min(1, max(0, (p - 0.30) / 0.45))
            return TransitionFX(
                outVolume: outVol,
                inVolume: inVol,
                outBassDB: -26 * handOver * handOver,
                inBassDB: -22 * (1 - received),
                outHighDB: -18 * p,
                inHighDB: -10 * (1 - received),
                outReverb: 44 * p,
                inReverb: 14 * (1 - p)
            )

        case .FILTER_TRANSITION:
            // Resonant high-cut sweep on the outgoing deck, wet tail growing with it.
            return TransitionFX(
                outVolume: outVol,
                inVolume: inVol,
                outBassDB: -30 * p,
                inBassDB: -12 * (1 - p),
                outHighDB: -36 * p * p,
                inHighDB: -6 * (1 - p),
                outReverb: 55 * p,
                inReverb: 10 * (1 - p)
            )

        case .ENERGY_BLEND, .BUILDUP_TO_DROP:
            let lift = min(1, max(0, (p - 0.35) / 0.65))
            return TransitionFX(
                outVolume: outVol,
                inVolume: inVol,
                outBassDB: -30 * lift,
                inBassDB: -18 * (1 - min(1, p / 0.30)),
                outHighDB: -14 * p,
                inHighDB: -12 * (1 - p),
                outReverb: 38 * p,
                inReverb: 8 * (1 - p)
            )

        case .ECHO_OUT, .LOOP_TRANSITION:
            // The outgoing track dissolves into its own tail.
            return TransitionFX(
                outVolume: outVol * (1 - 0.35 * p),
                inVolume: inVol,
                outBassDB: -24 * p,
                inBassDB: -14 * (1 - p),
                outHighDB: -20 * p,
                inHighDB: 0,
                outReverb: 72 * p,
                inReverb: 0
            )

        case .VOCAL_CUT:
            return TransitionFX(
                outVolume: outVol,
                inVolume: inVol,
                outBassDB: -22 * p,
                inBassDB: -16 * (1 - min(1, p / 0.35)),
                outHighDB: -24 * p,
                inHighDB: 0,
                outReverb: 50 * p,
                inReverb: 0
            )

        case .DROP_SWITCH, .HARD_CUT:
            let fade = min(1, p / 0.2)
            return TransitionFX(
                outVolume: 1 - fade,
                inVolume: 1,
                outBassDB: -36 * fade,
                inBassDB: 0,
                outHighDB: -30 * fade,
                inHighDB: 0,
                outReverb: 45 * fade,
                inReverb: 0
            )

        case .SILENCE_TRIM, .SIMPLE_CROSSFADE, .INSTRUMENTAL_OVERLAY, .NONE:
            return TransitionFX(
                outVolume: outVol,
                inVolume: inVol,
                outBassDB: -10 * p,
                inBassDB: -8 * (1 - p),
                outHighDB: 0,
                inHighDB: 0,
                outReverb: 0,
                inReverb: 0
            )
        }
    }

    private func baseBandGain(_ index: Int) -> Float {
        eqEnabled ? eqGains[index] : 0
    }

    private func applyBandOffsets(_ eq: AVAudioUnitEQ, bassDB: Float, highDB: Float) {
        eq.bands[0].gain = baseBandGain(0) + bassDB
        eq.bands[1].gain = baseBandGain(1) + bassDB * 0.85
        eq.bands[2].gain = baseBandGain(2) + bassDB * 0.55
        eq.bands[7].gain = baseBandGain(7) + highDB * 0.45
        eq.bands[8].gain = baseBandGain(8) + highDB * 0.80
        eq.bands[9].gain = baseBandGain(9) + highDB
    }

    private func tickTransition() {
        guard let start = transitionStartTime, isTransitioning else { return }
        let elapsed = -start.timeIntervalSinceNow
        let p = min(elapsed / transitionDuration, 1.0)
        AutoMixDJEngine.shared.transitionProgress = p

        let strategy = AutoMixDJEngine.shared.activePlan?.strategy ?? .BASS_SWAP
        let fx = automation(progress: p, strategy: strategy)

        if isUsingStreamPlayer {
            activeStreamingPlayer.volume = max(0, min(1, fx.outVolume)) * volume
            idleStreamingPlayer.volume = max(0, min(1, fx.inVolume)) * volume
            if abs(outgoingTempoRate - 1) > 0.001 {
                activeStreamingPlayer.rate = 1 + (outgoingTempoRate - 1) * Float(p)
            }
        } else {
            activePlayer.volume = fx.outVolume * volume
            idlePlayer.volume = fx.inVolume * volume

            applyBandOffsets(activeEQ, bassDB: fx.outBassDB, highDB: fx.outHighDB)
            applyBandOffsets(idleEQ, bassDB: fx.inBassDB, highDB: fx.inHighDB)

            activeReverb.wetDryMix = max(0, min(100, fx.outReverb))
            idleReverb.wetDryMix = max(0, min(100, fx.inReverb))

            // Gradual tempo ramp of the outgoing deck, like a DJ nudging the pitch fader.
            if abs(outgoingTempoRate - 1) > 0.001 {
                let rate = 1 + (outgoingTempoRate - 1) * Float(p)
                activeTimePitch.rate = rate
                anchorOffset += Double(rate - 1) * transitionTick
            }
        }

        if p >= 1.0, let incomingTrack {
            completeTransition(to: incomingTrack)
        }
    }

    private func completeTransition(to nextTrack: Track) {
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil

        let blend = transitionDuration
        let startPosition = activeTransitionPlan?.targetTrack.startPosition ?? 0
        let promoted = max(0, startPosition + blend * Double(incomingTempoRate))

        activeTransitionPlan = nil
        isPlanningTransition = false

        if isUsingStreamPlayer {
            activeStreamingPlayer.pause()
            activeStreamingPlayer.replaceCurrentItem(with: nil)
            let oldActive = activeStreamingPlayer
            activeStreamingPlayer = idleStreamingPlayer
            idleStreamingPlayer = oldActive
            activeStreamingPlayer.volume = volume
            activeStreamingPlayer.rate = 1.0
            progress = promoted
        } else {
            let oldActive = activePlayer
            let oldReverb = activeReverb
            let oldTimePitch = activeTimePitch
            oldActive.stop()
            oldActive.volume = 1.0
            oldReverb.wetDryMix = 0
            oldTimePitch.rate = 1.0

            generation += 1
            activePlayer = idlePlayer
            activeAudioFile = incomingAudioFile
            incomingAudioFile = nil
            activePlayer.volume = volume
            activeReverb.wetDryMix = 0
            applyEQ()

            anchorDate = Date()
            anchorOffset = promoted
            pausedProgress = promoted
            progress = promoted
            startRateRelease()
        }

        incomingTrack = nil
        prebufferedTrackId = nil
        currentTrack = nextTrack
        streamDuration = nextTrack.duration
        isTransitioning = false
        transitionScheduled = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixDJEngine.shared.statusBadge = nil
        if let bpm = analysisCache[nextTrack.id]?.bpm { AutoMixDJEngine.shared.currentBPM = bpm }

        SonivoDiagnostics.log("[AutoMix] Transition completed: now playing \(nextTrack.title) at \(String(format: "%.1f", promoted))s", tag: "AUTOMIX")

        prewarmAnalysis(for: nextTrack)
        if let upcoming = peekNext(auto: true) { prewarmAnalysis(for: upcoming) }

        lastNowPlayingSync = nil
        updateNowPlayingInfo()
        savePlaybackState()
    }

    private func cancelTransition() {
        transitionScheduled = false
        activeTransitionPlan = nil
        guard isTransitioning else { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil
        idlePlayer.stop()
        idlePlayer.volume = 0
        activePlayer.volume = volume
        activeStreamingPlayer.volume = volume
        idleStreamingPlayer.pause()
        idleStreamingPlayer.volume = 0
        incomingAudioFile = nil
        isTransitioning = false
        stopRateRelease()
        timePitchA.rate = 1.0
        timePitchB.rate = 1.0
        reverbA.wetDryMix = 0
        reverbB.wetDryMix = 0
        incomingTempoRate = 1.0
        outgoingTempoRate = 1.0
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixDJEngine.shared.statusBadge = nil
        applyEQ()
    }

    // MARK: - AutoMix Playback Rate & Anchor Helpers

    /// After a beat-matched blend the new track is still running at the mix tempo.
    /// Ease it back to its own tempo instead of snapping, exactly like a CDJ.
    private func startRateRelease() {
        guard abs(incomingTempoRate - 1) > 0.0005 else {
            activeTimePitch.rate = 1.0
            return
        }
        rateReleaseFrom = incomingTempoRate
        rateReleaseStart = Date()
        activeTimePitch.rate = incomingTempoRate
        rateReleaseTimer?.invalidate()
        let timer = Timer(timeInterval: rateReleaseTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRateRelease() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rateReleaseTimer = timer
    }

    private func tickRateRelease() {
        guard let start = rateReleaseStart, !isUsingStreamPlayer else { stopRateRelease(); return }
        let p = min(1, max(0, -start.timeIntervalSinceNow / rateReleaseDuration))
        let eased = Float(p * p * (3 - 2 * p))
        let rate = rateReleaseFrom + (1 - rateReleaseFrom) * eased
        activeTimePitch.rate = rate
        anchorOffset += Double(rate - 1) * rateReleaseTick
        if p >= 1 {
            activeTimePitch.rate = 1.0
            incomingTempoRate = 1.0
            stopRateRelease()
        }
    }

    private func stopRateRelease() {
        rateReleaseTimer?.invalidate()
        rateReleaseTimer = nil
        rateReleaseStart = nil
        rateReleaseFrom = 1.0
    }

    func setOutgoingPlaybackRate(_ rate: Float) {
        let clamped = min(1.15, max(0.85, rate))
        if isUsingStreamPlayer {
            activeStreamingPlayer.rate = clamped
        } else {
            activeTimePitch.rate = clamped
        }
    }

    func setIncomingPlaybackRate(_ rate: Float) {
        let clamped = min(1.15, max(0.85, rate))
        if isUsingStreamPlayer {
            idleStreamingPlayer.rate = clamped
        } else {
            idleTimePitch.rate = clamped
        }
    }

    func resetPlaybackRates() {
        if isUsingStreamPlayer {
            activeStreamingPlayer.rate = isPlaying ? 1.0 : 0.0
            idleStreamingPlayer.rate = 0.0
        } else {
            timePitchA.rate = 1.0
            timePitchB.rate = 1.0
        }
    }

    func nudgePlaybackAnchor(by drift: TimeInterval) {
        anchorOffset += drift
    }

    // MARK: - Finish & Queue

    private func handleTrackFinish() {
        // If an automix/crossfade is already handling the transition, ignore this
        // (the outgoing track's segment also fires its completion mid-crossfade).
        guard !isTransitioning, !transitionScheduled else { return }
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

    func removeFromQueue(_ track: Track) {
        queue.removeAll { $0.id == track.id }
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
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func tickProgress() {
        guard isPlaying, !isUsingStreamPlayer else { return }
        progress = liveProgress()
        syncNowPlayingElapsedIfNeeded()
        scheduleTransitionIfNeeded()
    }

    func formatted(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Sleep Timer

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = nil
        sleepTimerRemaining = nil
        sleepTimerMinutes = nil
        guard let minutes, minutes > 0 else { return }
        sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerRemaining = Double(minutes) * 60
        sleepTimerMinutes = minutes
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSleepTimer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    private func tickSleepTimer() {
        guard let deadline = sleepDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            pause()
            cancelSleepTimer()
        } else {
            sleepTimerRemaining = remaining
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = nil
        sleepTimerRemaining = nil
        sleepTimerMinutes = nil
    }

    // MARK: - Spectrum tap

    private var spectrumTapInstalled = false

    nonisolated private static func handleSpectrumTap(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        SpectrumAnalyzer.ingest(buffer: buffer, sampleRate: buffer.format.sampleRate)
    }

    func installSpectrumTap() {
        guard !spectrumTapInstalled else { return }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        mixer.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.handleSpectrumTap)
        spectrumTapInstalled = true
    }
}
