@preconcurrency import AVFoundation
import AudioToolbox
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
        case .hiResLossless: return "Без потерь, максимальный битрейт (FLAC)"
        case .lossless: return "Без потерь (FLAC 16-bit / 44.1 kHz)"
        case .hq: return "Высокое качество (AAC / MP3 320 kbps)"
        case .auto: return "Автоматически (По скорости сети)"
        case .economical: return "Экономия трафика (64-128 kbps)"
        }
    }

    var badgeText: String {
        switch self {
        case .hiResLossless: return "Lossless"
        case .lossless: return "Lossless"
        case .hq: return "HQ"
        case .auto: return "Lossless"
        case .economical: return "AAC"
        }
    }

    var detail: String {
        switch self {
        case .hiResLossless: return "Максимальный доступный битрейт FLAC без потерь. Если для конкретного трека FLAC недоступен на сервере, автоматически используется лучший поток из имеющихся."
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

// MARK: - Now Playing session delegate

nonisolated final class NowPlayingSessionObserver: NSObject, MPNowPlayingSessionDelegate {
    @objc func nowPlayingSessionDidChangeActive(_ nowPlayingSession: MPNowPlayingSession) {
        let active = nowPlayingSession.isActive
        Task { @MainActor in
            SonivoDiagnostics.log("[NowPlaying] Session active: \(active)", tag: "NOWPLAYING")
        }
    }

    @objc func nowPlayingSessionDidChangeCanBecomeActive(_ nowPlayingSession: MPNowPlayingSession) {
        let canBecomeActive = nowPlayingSession.canBecomeActive
        Task { @MainActor in
            SonivoDiagnostics.log("[NowPlaying] Session canBecomeActive: \(canBecomeActive)", tag: "NOWPLAYING")
            if canBecomeActive {
                PlayerCore.shared.activateNowPlayingSessionIfNeeded()
            }
        }
    }
}

// MARK: - Fast Progressive Audio & Local Playback Engine (PlayerCore)

@Observable
@MainActor
final class PlayerCore {
    static let shared = PlayerCore()
    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

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

    var transitionMode: TransitionMode = .automix { didSet { defaults.set(transitionMode.rawValue, forKey: "player.transitionMode") } }
    var crossfadeDuration: Double = 3.0 { didSet { defaults.set(crossfadeDuration, forKey: "player.crossfadeDuration") } }

    private(set) var currentBitrate: Int?
    private(set) var currentCodec: String?
    var audioQuality: AudioQuality = .auto { didSet { defaults.set(audioQuality.rawValue, forKey: "player.quality") } }

    private(set) var sleepTimerMinutes: Int? = nil
    private(set) var sleepTimerRemaining: Double? = nil
    private var sleepTimer: Timer?
    private var sleepDeadline: Date?

    private let defaults = UserDefaults.standard

    private var nowPlayingSession: MPNowPlayingSession?
    private var nowPlayingSessionObserver: NowPlayingSessionObserver?
    private var nowPlayingActivationInFlight = false
    private var lastRemoteCommand: (name: String, date: Date)?
    private var applicationIsActive = true

    private let streamingPlayerA = AVPlayer()
    private let streamingPlayerB = AVPlayer()
    private var activeStreamingPlayer: AVPlayer
    private var idleStreamingPlayer: AVPlayer
    var streamingPlayer: AVPlayer { activeStreamingPlayer }
    private var isUsingStreamPlayer = false
    private var isPrebufferingNextStream = false
    private var prebufferedTrackId: UUID? = nil
    private var activeTransitionPlan: TransitionPlan? = nil
    private var isPlanningTransition: Bool = false
    private var planningStartedAt: Date? = nil
    private var plannedNextTrack: Track? = nil
    private var incomingIsStream: Bool = false
    private var incomingLaneReady: Bool = false
    private var transitionScheduledAt: Date? = nil
    private var transitionPausedAt: Date? = nil

    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private var activePlayer: AVAudioPlayerNode
    private let timePitchA = AVAudioUnitTimePitch()
    private let timePitchB = AVAudioUnitTimePitch()
    private let reverbA = AVAudioUnitReverb()
    private let reverbB = AVAudioUnitReverb()
    private let eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)

    private let looperPlayer = AVAudioPlayerNode()
    private let looperTimePitch = AVAudioUnitTimePitch()
    private let looperEQ = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let looperReverb = AVAudioUnitReverb()
    private var loopBuffer: AVAudioPCMBuffer?
    private var isLoopActive = false

    private let outputLimiter = AVAudioUnitEffect(
        audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    )

    private var activeAudioFile: AVAudioFile?
    private var incomingAudioFile: AVAudioFile?
    private(set) var incomingTrack: Track?
    /// Mirrors `currentTrack` but flips ~250 ms before the audio engine
    /// actually completes the AutoMix hand-off, so the on-screen title/
    /// artist swap lines up with the perceived downbeat of the incoming
    /// track instead of visibly lagging behind it (screen-recording
    /// analysis: ~300 ms late at the actual hand-off).
    private(set) var metadataTrack: Track?
    private var metadataSwapped = false
    private var incomingStartPosition: Double = 0
    private var generation = 0
    private var anchorDate: Date?
    private var anchorOffset: Double = 0
    private var pausedProgress: Double = 0
    private var progressTimer: Timer?

    private var remoteArtworkCache: [UUID: UIImage] = [:]
    private var lastNowPlayingSync: Date?

    private var isTransitioning = false
    private var transitionScheduled = false
    private var transitionStartTime: Date?
    private var transitionDuration: Double = 3.0
    private var transitionTimer: Timer?
    private var rateReleaseTimer: Timer?

    /// Title/artist UI should read from this instead of `currentTrack`
    /// directly - it flips slightly ahead of the engine to fix the AutoMix
    /// metadata-sync lag noted in the screen-recording analysis.
    var displayTrack: Track? { metadataTrack ?? currentTrack }

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

    private init() {
        activePlayer = playerA
        activeStreamingPlayer = streamingPlayerA
        idleStreamingPlayer = streamingPlayerB
        configureSession()
        setupAudioEngine()
        setupStreamingPlayer()
        setupNowPlayingSession()
        loadSettings()
        setupRemoteCommandCenter()
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
        engine.attach(looperPlayer)
        engine.attach(timePitchA)
        engine.attach(timePitchB)
        engine.attach(looperTimePitch)
        engine.attach(eqNodeA)
        engine.attach(eqNodeB)
        engine.attach(looperEQ)
        engine.attach(reverbA)
        engine.attach(reverbB)
        engine.attach(looperReverb)

        configureEQ(eqNodeA)
        configureEQ(eqNodeB)
        configureEQ(looperEQ)
        configureTimePitch(timePitchA)
        configureTimePitch(timePitchB)
        configureTimePitch(looperTimePitch)
        configureReverb(reverbA)
        configureReverb(reverbB)
        configureReverb(looperReverb)

        engine.connect(playerA, to: timePitchA, format: nil)
        engine.connect(timePitchA, to: eqNodeA, format: nil)
        engine.connect(eqNodeA, to: reverbA, format: nil)
        engine.connect(reverbA, to: engine.mainMixerNode, format: nil)

        engine.connect(playerB, to: timePitchB, format: nil)
        engine.connect(timePitchB, to: eqNodeB, format: nil)
        engine.connect(eqNodeB, to: reverbB, format: nil)
        engine.connect(reverbB, to: engine.mainMixerNode, format: nil)

        engine.connect(looperPlayer, to: looperTimePitch, format: nil)
        engine.connect(looperTimePitch, to: looperEQ, format: nil)
        engine.connect(looperEQ, to: looperReverb, format: nil)
        engine.connect(looperReverb, to: engine.mainMixerNode, format: nil)

        looperPlayer.volume = 0

        engine.attach(outputLimiter)
        engine.connect(engine.mainMixerNode, to: outputLimiter, format: nil)
        engine.connect(outputLimiter, to: engine.outputNode, format: nil)

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
        for (i, band) in looperEQ.bands.enumerated() { band.gain = eqEnabled ? eqGains[i] : 0 }
    }

    private var activeEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeA : eqNodeB }
    private var idleEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeB : eqNodeA }
    private var idlePlayer: AVAudioPlayerNode { (activePlayer === playerA) ? playerB : playerA }
    private var activeTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchA : timePitchB }
    private var idleTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchB : timePitchA }
    private var activeReverb: AVAudioUnitReverb { (activePlayer === playerA) ? reverbA : reverbB }
    private var idleReverb: AVAudioUnitReverb { (activePlayer === playerA) ? reverbB : reverbA }

    private func setupNowPlayingSession() {
        // Стандартная нативная архитектура: используем MPNowPlayingInfoCenter.default()
        // MPNowPlayingSession вызывала сторонний виджет на Dynamic Island внутри приложения
        SonivoDiagnostics.log("[NowPlaying] Configured MPNowPlayingInfoCenter.default()", tag: "NOWPLAYING")
    }

    func activateNowPlayingSessionIfNeeded() {
        // No-op: MPNowPlayingInfoCenter.default() синхронизирован с AVAudioSession
    }

    private func publishNowPlaying(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        let defaultCenter = MPNowPlayingInfoCenter.default()
        defaultCenter.nowPlayingInfo = info
        defaultCenter.playbackState = state
    }

    func setApplicationSceneActive(_ active: Bool) {
        guard applicationIsActive != active else { return }
        applicationIsActive = active
        updateNowPlayingInfo()
    }

    private func shouldHandleRemote(_ name: String) -> Bool {
        let now = Date()
        if let last = lastRemoteCommand, last.name == name, now.timeIntervalSince(last.date) < 0.3 {
            return false
        }
        lastRemoteCommand = (name, now)
        return true
    }

    private func setupRemoteCommandCenter() {
        var centers: [MPRemoteCommandCenter] = [MPRemoteCommandCenter.shared()]
        if let sessionCenter = nowPlayingSession?.remoteCommandCenter, sessionCenter !== MPRemoteCommandCenter.shared() {
            centers.append(sessionCenter)
        }
        for center in centers {
            configureRemoteCommands(center)
        }
    }

    private func configureRemoteCommands(_ commandCenter: MPRemoteCommandCenter) {
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
            Task { @MainActor in
                guard let self, self.shouldHandleRemote("play") else { return }
                self.resume()
            }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldHandleRemote("pause") else { return }
                self.pause()
            }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldHandleRemote("toggle") else { return }
                self.togglePlay()
            }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldHandleRemote("next") else { return }
                self.next()
            }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldHandleRemote("previous") else { return }
                self.previous()
            }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in
                guard let self, self.shouldHandleRemote("seek") else { return }
                self.seek(to: target)
            }
            return .success
        }
    }

    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let data = image.pngData() ?? Data()
        let size = image.size
        return MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(data: data) ?? UIImage()
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            publishNowPlaying(nil, state: .stopped)
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

        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = track.id.uuidString
        if !track.isStream, track.url.isFileURL {
            info[MPNowPlayingInfoPropertyAssetURL] = track.url
        } else if let stream = track.streamUrlString, let url = URL(string: stream) {
            info[MPNowPlayingInfoPropertyAssetURL] = url
        }

        if let image = LibraryStore.cachedArtworkImage(for: track) {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
        } else if let image = remoteArtworkCache[track.id] {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
        }

        publishNowPlaying(info, state: isPlaying ? .playing : .paused)
        lastNowPlayingSync = Date()
        activateNowPlayingSessionIfNeeded()

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
                self.publishNowPlaying(current, state: self.isPlaying ? .playing : .paused)
            }
        }
    }

    private func syncNowPlayingElapsedIfNeeded() {
        guard currentTrack != nil else { return }
        let now = Date()
        if let last = lastNowPlayingSync, now.timeIntervalSince(last) < 2.0 { return }
        lastNowPlayingSync = now

        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo, !info.isEmpty else {
            updateNowPlayingInfo()
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = isUsingStreamPlayer ? progress : liveProgress()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = duration
        publishNowPlaying(info, state: isPlaying ? .playing : .paused)
        activateNowPlayingSessionIfNeeded()
    }

    func togglePlay() {
        if currentTrack == nil {
            let source = queue.isEmpty ? LibraryStore.shared.tracks : queue
            if let first = source.first { play(first, newQueue: source) }
            return
        }
        isPlaying ? pause() : resume()
    }

    func play(_ track: Track, newQueue: [Track]? = nil) {
        flushListeningStats()
        reportWaveSkipIfNeeded()
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
            if isLoopActive { looperPlayer.pause() }
            if incomingIsStream {
                idleStreamingPlayer.pause()
            } else {
                idlePlayer.pause()
            }
            anchorDate = nil
            progress = pausedProgress
        }
        if isTransitioning, transitionStartTime != nil {
            transitionPausedAt = Date()
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
            if isLoopActive { looperPlayer.play() }
            if isTransitioning {
                if incomingIsStream {
                    idleStreamingPlayer.play()
                } else {
                    idlePlayer.play()
                }
            }
            isPlaying = true
            anchorDate = Date()
            anchorOffset = pausedProgress
            startTimer()
        }
        if isTransitioning, let paused = transitionPausedAt, let start = transitionStartTime {
            let frozen = paused.timeIntervalSince(start)
            transitionStartTime = Date().addingTimeInterval(-frozen)
            transitionPausedAt = nil
        }
        updateNowPlayingInfo()
        savePlaybackState()
    }

    func next() {
        cancelTransition()
        reportWaveSkipIfNeeded()
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
        reportWaveSkipIfNeeded()
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
        stopBeatLoop()
        activeAudioFile = nil
        incomingAudioFile = nil
        currentTrack = nil
        metadataTrack = nil
        metadataSwapped = false
        isPlaying = false
        progress = 0
        pausedProgress = 0
        streamDuration = 0
        anchorDate = nil
        cancelTransition()
        SpectrumAnalyzer.shared.reset()
        updateNowPlayingInfo()
    }

    private func start(at seconds: Double) {
        guard let track = currentTrack else { return }
        playError = nil
        activeTransitionPlan = nil
        plannedNextTrack = nil
        generation += 1
        let token = generation
        isPlanningTransition = false
        planningStartedAt = nil

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
        stopBeatLoop()
        playerA.volume = 1.0
        playerB.volume = 0.0
        activePlayer = playerA
        rateReleaseTimer?.invalidate()
        rateReleaseTimer = nil
        timePitchA.rate = 1.0
        timePitchA.bypass = true
        timePitchB.rate = 1.0
        timePitchB.bypass = true
        reverbA.wetDryMix = 0
        reverbB.wetDryMix = 0
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

    private func startStream(_ track: Track, at seconds: Double, token: Int) {
        isUsingStreamPlayer = true
        playerA.stop()
        playerB.stop()
        stopBeatLoop()

        let url = track.url
        if url.scheme == "http" || url.scheme == "https" {
            currentBitrate = 128
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
        guard !(url.scheme == "http" || url.scheme == "https") else { return }
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
        item.audioTimePitchAlgorithm = .timeDomain
        item.isAudioSpatializationAllowed = true
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
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

    private func scheduleTransitionIfNeeded() {
        guard transitionMode != .off, !isTransitioning, !transitionScheduled, isPlaying, let current = currentTrack else { return }

        if transitionMode == .crossfade {
            scheduleSimpleTransition(current: current, blendDuration: max(1, crossfadeDuration))
            return
        }
        if transitionMode == .gapless {
            scheduleSimpleTransition(current: current, blendDuration: 0.1)
            return
        }

        let currentPos = isUsingStreamPlayer ? progress : liveProgress()
        let totalDur = duration
        guard totalDur >= 30.0 else { return }

        // Apple Music AutoMix strictly triggers during the outro of a track.
        // Never trigger or plan during the first 35s or before the halfway mark!
        guard currentPos >= min(35.0, totalDur * 0.50) else { return }

        let nextTrack: Track
        if let planned = plannedNextTrack, planned.id != current.id {
            nextTrack = planned
        } else if let peeked = peekNext(auto: true) {
            plannedNextTrack = peeked
            nextTrack = peeked
        } else {
            return
        }

        let remaining = totalDur - currentPos
        guard remaining <= 65.0 else { return }

        if let queued = queue.firstIndex(where: { $0.id == nextTrack.id }), !nextTrack.isStream, !FileManager.default.fileExists(atPath: nextTrack.url.path) {
            _ = queued
            plannedNextTrack = nil
            return
        }

        if remaining <= 65.0, activeTransitionPlan == nil, !isPlanningTransition {
            isPlanningTransition = true
            planningStartedAt = Date()
            Task {
                let srcAnalysis = await TrackAnalysisService.shared.analysis(for: current)
                    ?? TrackAnalysis.minimal(trackID: current.id.uuidString, duration: totalDur)
                let tgtAnalysis = await TrackAnalysisService.shared.analysis(for: nextTrack)
                    ?? TrackAnalysis.minimal(trackID: nextTrack.id.uuidString, duration: nextTrack.duration)

                let plan = await GeminiAutoMixPlanner.shared.planTransition(
                    sourceTrack: current,
                    sourceAnalysis: srcAnalysis,
                    targetTrack: nextTrack,
                    targetAnalysis: tgtAnalysis,
                    currentPosition: currentPos
                )

                await MainActor.run {
                    guard self.currentTrack?.id == current.id, !self.isTransitioning else { return }
                    self.activeTransitionPlan = plan
                    self.isPlanningTransition = false
                    self.planningStartedAt = nil
                    AutoMixDJEngine.shared.currentBPM = plan.tempo.targetBPM
                }
            }
        }

        let cueRemaining = max(totalDur - (activeTransitionPlan?.cueTime ?? (totalDur - 20.0)), activeTransitionPlan?.leadTime ?? 18.0)
        let prebufferThreshold = cueRemaining + 16.0
        if nextTrack.isStream, remaining <= prebufferThreshold, prebufferedTrackId != nextTrack.id, !isPrebufferingNextStream {
            isPrebufferingNextStream = true
            let ymID = Self.yandexTrackID(from: nextTrack)
            let targetStart = max(0, activeTransitionPlan?.targetTrack.startPosition ?? 0)
            Task {
                do {
                    let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                    let resolvedStart = self.activeTransitionPlan != nil ? targetStart : 0
                    let nextItem = AVPlayerItem(url: info.url)
                    nextItem.audioTimePitchAlgorithm = .timeDomain
                    nextItem.isAudioSpatializationAllowed = true
                    nextItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
                    StreamBeatTap.shared.attach(to: nextItem)
                    self.idleStreamingPlayer.replaceCurrentItem(with: nextItem)
                    self.idleStreamingPlayer.volume = 0
                    self.idleStreamingPlayer.seek(to: CMTime(seconds: resolvedStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
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
        let effectiveCueTime = max(plan.cueTime, totalDur - 35.0)
        guard currentPos >= effectiveCueTime, (totalDur - currentPos) > 0.05 else { return }

        if effectiveCueTime > currentPos + 1.0 { return }

        transitionScheduled = true
        isTransitioning = true
        incomingLaneReady = false
        transitionDuration = plan.leadTime
        incomingTrack = nextTrack
        metadataSwapped = false
        metadataTrack = nil
        // Critical: without this, the tickTransition volume/rate branches below
        // ("if incomingIsStream { idleStreamingPlayer... } else { idlePlayer... }")
        // always fell into the AVAudioEngine branch for a track that was
        // actually playing on the AVPlayer streaming lane. The engine's idle
        // node was silent and unused, so the real incoming stream's volume
        // never left the near-zero value it was parked at during pre-buffer,
        // and its rate never ramped for beat matching either - the blend ran
        // completely inaudibly until the hard cut in completeTransition().
        incomingIsStream = nextTrack.isStream
        incomingStartPosition = max(0, plan.targetTrack.startPosition)
        AutoMixDJEngine.shared.isTransitionActive = true
        AutoMixDJEngine.shared.activeStrategyName = plan.decision.transitionType
        AutoMixDJEngine.shared.activePlan = plan
        applyReverbPreset(plan.effects.resolvedReverbPreset)

        SonivoDiagnostics.log("[AutoMix] Transition: \(currentTrack?.title ?? "?") -> \(nextTrack.title) [\(plan.strategy.rawValue), \(String(format: "%.1f", transitionDuration))s, rate in \(String(format: "%.3f", plan.tempo.targetPlaybackRate)), \(plan.decision.reason)]", tag: "AUTOMIX")

        if isUsingStreamPlayer || nextTrack.isStream {
            guard idleStreamingPlayer.currentItem != nil, prebufferedTrackId == nextTrack.id else {
                isTransitioning = false
                transitionScheduled = false
                AutoMixDJEngine.shared.isTransitionActive = false
                return
            }
            let laneStart = max(0, plan.targetTrack.startPosition)
            let seekTime = CMTime(seconds: laneStart, preferredTimescale: 600)
            idleStreamingPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isTransitioning, self.incomingTrack?.id == nextTrack.id else { return }
                    self.idleStreamingPlayer.volume = 0.001
                    self.idleStreamingPlayer.currentItem?.audioTimePitchAlgorithm = .timeDomain
                    self.idleStreamingPlayer.playImmediately(atRate: 1.0)
                    self.transitionStartTime = Date()
                    self.incomingLaneReady = true
                    self.startTransitionTimer()
                }
            }
            return
        }

        // Both lanes are switched into the signal path once, up front, instead
        // of flipping AVAudioUnitTimePitch.bypass on and off every animation
        // tick as the rate crosses 1.0. Toggling an Audio Unit's bypass state
        // while audio is actively flowing through it produces an audible
        // click/pop right at that instant.
        activeTimePitch.bypass = false
        idleTimePitch.bypass = false
        let targetIdlePlayer = idlePlayer
        let targetIsPlayerA = targetIdlePlayer === playerA
        let targetStart = max(0, plan.targetTrack.startPosition)

        let outgoingURL = currentTrack?.url
        Task { [weak self] in
            guard let self, let outgoingURL, outgoingURL.isFileURL, !nextTrack.isStream, !self.isUsingStreamPlayer else { return }
            let outgoingAnalysis = await TrackAnalysisService.shared.analysis(for: current)
                ?? TrackAnalysis.minimal(trackID: current.id.uuidString, duration: totalDur)
            await MainActor.run {
                guard self.isTransitioning, self.incomingTrack?.id == nextTrack.id else { return }
                let tailSilence = outgoingAnalysis.trailingSilence?.duration ?? 0
                let musicRunway = totalDur - tailSilence - plan.cueTime
                let runsOutOfMusic = musicRunway < transitionDuration * 0.9
                let wantsLoop = plan.strategy == .LOOP_TRANSITION || plan.strategy == .ECHO_OUT || runsOutOfMusic
                if wantsLoop {
                    self.startBeatLoop(url: outgoingURL, analysis: outgoingAnalysis, cueTime: plan.cueTime, blend: transitionDuration)
                }
            }
        }

        Task {
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile

                let sampleRate = nextFile.processingFormat.sampleRate
                let requestedFrame: AVAudioFramePosition = AVAudioFramePosition(max(0, targetStart) * sampleRate)
                let lastFrame: AVAudioFramePosition = max(0, nextFile.length - 1)
                let startFrame = min(requestedFrame, lastFrame)
                let frameCount = AVAudioFrameCount(max(0, nextFile.length - startFrame))
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: startFrame, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self,
                              self.activePlayer === (targetIsPlayerA ? self.playerA : self.playerB) else { return }
                        self.handleTrackFinish()
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
                AutoMixDJEngine.shared.isTransitionActive = false
                SonivoDiagnostics.log("[AutoMix] Local lane setup failed: \(error.localizedDescription)", tag: "AUTOMIX")
            }
        }
    }

    private func startBeatLoop(url: URL, analysis: TrackAnalysis, cueTime: Double, blend: Double) {
        guard analysis.hasSteadyBeat else { return }
        guard let bar = analysis.barDuration, bar.isFinite, bar > 0.3, bar < 8 else { return }

        var bars: Double = 2
        if bar * bars > blend { bars = 1 }
        let loopLength = bar * bars
        let rawStart = cueTime - loopLength
        guard rawStart > 0.5 else { return }
        let loopStart = analysis.nearestDownbeat(to: rawStart, tolerance: bar * 0.6) ?? rawStart
        guard loopStart > 0.2 else { return }

        Task {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let sr = format.sampleRate
                guard sr > 0 else { return }

                let startFrame = AVAudioFramePosition(loopStart * sr)
                guard startFrame >= 0, startFrame < file.length else { return }
                let available = file.length - startFrame
                let wanted = AVAudioFramePosition(loopLength * sr)
                let frames = AVAudioFrameCount(max(0, min(wanted, available)))
                guard frames > 2048 else { return }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }

                file.framePosition = startFrame
                try file.read(into: buffer, frameCount: frames)

                guard self.isTransitioning, !self.isUsingStreamPlayer else { return }

                self.loopBuffer = buffer
                self.looperPlayer.stop()
                self.looperPlayer.volume = self.volume
                self.looperTimePitch.rate = 1.0
                self.looperReverb.wetDryMix = 0
                for (i, band) in self.looperEQ.bands.enumerated() {
                    band.gain = self.eqEnabled ? self.eqGains[i] : 0
                }
                if !self.engine.isRunning { try? self.engine.start() }
                self.looperPlayer.scheduleBuffer(buffer, at: nil, options: [.loops])
                self.looperPlayer.play()
                self.isLoopActive = true

                SonivoDiagnostics.log("[AutoMix] Outro beat-loop from \(String(format: "%.2f", loopStart))s, \(Int(bars)) bar(s) = \(String(format: "%.2f", loopLength))s", tag: "AUTOMIX")
            } catch {
                SonivoDiagnostics.log("[AutoMix] Beat-loop failed: \(error.localizedDescription)", tag: "AUTOMIX")
            }
        }
    }

    private func scheduleSimpleTransition(current: Track, blendDuration: Double) {
        let currentPos = isUsingStreamPlayer ? progress : liveProgress()
        let totalDur = duration
        let cue = max(0, totalDur - blendDuration)
        guard totalDur > 5, currentPos >= cue, let nextTrack = peekNext(auto: true) else { return }

        transitionScheduled = true
        isTransitioning = true
        incomingIsStream = nextTrack.isStream
        transitionDuration = blendDuration
        incomingTrack = nextTrack
        metadataSwapped = false
        metadataTrack = nil
        incomingStartPosition = 0
        AutoMixDJEngine.shared.isTransitionActive = transitionMode == .crossfade
        AutoMixDJEngine.shared.activeStrategyName = transitionMode == .crossfade ? "CROSSFADE" : "GAPLESS"
        AutoMixDJEngine.shared.activePlan = nil
        AutoMixDJEngine.shared.transitionProgress = 0

        if isUsingStreamPlayer || nextTrack.isStream {
            if idleStreamingPlayer.currentItem == nil || prebufferedTrackId != nextTrack.id {
                let ymID = Self.yandexTrackID(from: nextTrack)
                Task { @MainActor in
                    do {
                        let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                        let nextItem = AVPlayerItem(url: info.url)
                        nextItem.audioTimePitchAlgorithm = .timeDomain
                        nextItem.isAudioSpatializationAllowed = true
                        nextItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
                        StreamBeatTap.shared.attach(to: nextItem)
                        self.idleStreamingPlayer.replaceCurrentItem(with: nextItem)
                        self.idleStreamingPlayer.volume = 0.001
                        self.idleStreamingPlayer.playImmediately(atRate: 1.0)
                        self.transitionStartTime = Date()
                        self.startTransitionTimer()
                    } catch {
                        self.isTransitioning = false
                        self.transitionScheduled = false
                        self.AutoMixDJEngineCleanup()
                    }
                }
            } else {
                idleStreamingPlayer.volume = 0.001
                idleStreamingPlayer.playImmediately(atRate: 1.0)
                transitionStartTime = Date()
                startTransitionTimer()
            }
            return
        }

        let targetIdlePlayer = idlePlayer
        let targetIsPlayerA = targetIdlePlayer === playerA
        Task { @MainActor in
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile
                let frameCount = AVAudioFrameCount(max(0, nextFile.length))
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: 0, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self,
                              self.activePlayer === (targetIsPlayerA ? self.playerA : self.playerB) else { return }
                        self.handleTrackFinish()
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
                self.AutoMixDJEngineCleanup()
            }
        }
    }

    private func stopBeatLoop() {
        looperPlayer.stop()
        looperPlayer.volume = 0
        looperTimePitch.rate = 1.0
        looperReverb.wetDryMix = 0
        loopBuffer = nil
        isLoopActive = false
    }

    private func AutoMixDJEngineCleanup() {
        incomingTrack = nil
        incomingLaneReady = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
    }

    private func startTransitionTimer() {
        transitionTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTransition() }
        }
        RunLoop.main.add(t, forMode: .common)
        transitionTimer = t
    }

    private func tickTransition() {
        guard let start = transitionStartTime, isTransitioning else { return }
        let elapsed = -start.timeIntervalSinceNow
        let p = min(elapsed / transitionDuration, 1.0)
        AutoMixDJEngine.shared.transitionProgress = p
        let blendTime = p * transitionDuration

        let strategy = AutoMixDJEngine.shared.activePlan?.strategy
            ?? TransitionStrategy(rawValue: AutoMixDJEngine.shared.activeStrategyName)
            ?? .BASS_SWAP
        let actions = AutoMixDJEngine.shared.activePlan?.actions ?? []
        let rates = AutoMixDJEngine.shared.activePlan?.tempo

        let hasEnvelopes = actions.contains { $0.target == "source" && $0.parameter == "volume" }
            && actions.contains { $0.target == "target" && $0.parameter == "volume" }

        let (outVol, inVol, outBassCut, inBassGain, filterCutoff) = AutoMixDJEngine.shared.computeVolumesAndEQ(progress: p, strategy: strategy)

        var sourceLevel = outVol
        var targetLevel = inVol
        if hasEnvelopes {
            if let outEnv = AutoMixDJEngine.sampleEnvelope(actions, target: "source", parameter: "volume", at: blendTime, defaultValue: 1.0) {
                sourceLevel = max(0, min(1.0, outEnv))
            }
            if let inEnv = AutoMixDJEngine.sampleEnvelope(actions, target: "target", parameter: "volume", at: blendTime, defaultValue: 0.0) {
                targetLevel = max(0, min(1.0, inEnv))
            }
        }

        var streamSourceVol = sourceLevel
        var streamTargetVol = targetLevel

        if strategy == .BASS_SWAP {
            // Cut 60% power at midpoint for bass swap; incoming punches in
            if p > 0.40 && p < 0.85 {
                let dropPct = Float((p - 0.40) / 0.45)
                streamSourceVol *= max(0.20, 1.0 - dropPct * 0.65)
            }
            if p > 0.35 {
                let risePct = Float((p - 0.35) / 0.65)
                streamTargetVol = max(streamTargetVol, min(1.0, Float(pow(risePct, 0.7))))
            }
        } else if strategy == .BUILDUP_TO_DROP || strategy == .DROP_SWITCH {
            if p > 0.60 {
                streamSourceVol *= max(0.05, Float(1.0 - (p - 0.60) / 0.40))
            }
        }

        if isUsingStreamPlayer {
            activeStreamingPlayer.volume = streamSourceVol * volume
        } else {
            activePlayer.volume = sourceLevel * volume
        }

        if incomingIsStream {
            idleStreamingPlayer.volume = streamTargetVol * volume
        } else {
            idlePlayer.volume = targetLevel * volume
        }

        if !isUsingStreamPlayer {
            var outLowDB = outBassCut
            var inLowDB = inBassGain
            if let outLow = AutoMixDJEngine.sampleEnvelope(actions, target: "source", parameter: "lowEQ", at: blendTime, defaultValue: 1.0) {
                outLowDB = max(-30.0, min(0.0, (outLow - 1) * 24.0))
            }
            if let inLow = AutoMixDJEngine.sampleEnvelope(actions, target: "target", parameter: "lowEQ", at: blendTime, defaultValue: 0.0) {
                inLowDB = max(-30.0, min(0.0, (inLow - 1) * 24.0))
            }
            activeEQ.bands[0].gain = eqEnabled ? (eqGains[0] + outLowDB) : outLowDB
            activeEQ.bands[1].gain = eqEnabled ? (eqGains[1] + outLowDB * 0.8) : (outLowDB * 0.8)
            activeEQ.bands[2].gain = eqEnabled ? (eqGains[2] + outLowDB * 0.5) : (outLowDB * 0.5)

            idleEQ.bands[0].gain = eqEnabled ? (eqGains[0] + inLowDB) : inLowDB
            idleEQ.bands[1].gain = eqEnabled ? (eqGains[1] + inLowDB) : inLowDB
            idleEQ.bands[2].gain = eqEnabled ? (eqGains[2] + inLowDB) : inLowDB
        }

        let outReverbMix = AutoMixDJEngine.sampleEnvelope(actions, target: "source", parameter: "reverb", at: blendTime, defaultValue: 0.0) ?? 0
        let inReverbMix = AutoMixDJEngine.sampleEnvelope(actions, target: "target", parameter: "reverb", at: blendTime, defaultValue: 0.0) ?? 0
        if !isUsingStreamPlayer {
            activeReverb.wetDryMix = max(0, min(100, outReverbMix * 100))
            if !incomingIsStream {
                idleReverb.wetDryMix = max(0, min(100, inReverbMix * 100))
            }
        }

        // Tempo ramps for beat matching: streamed lanes ride AVPlayer.rate
        // (audioTimePitchAlgorithm keeps the pitch); engine lanes use the
        // pitch-corrected time-pitch nodes.
        // Iconic DJ Vinyl Brake / Tape Slowdown ("Зажёвывание" как в Apple Music)
        let isBrakeStrategy = strategy == .DROP_SWITCH || strategy == .VOCAL_CUT || strategy == .FILTER_TRANSITION || strategy == .HARD_CUT || strategy == .ECHO_OUT

        if isBrakeStrategy {
            if p > 0.15 {
                let brakeP = Float((p - 0.15) / 0.85)
                let brakeRate = max(0.04, Float(1.0 - brakeP * 0.96))
                if !isUsingStreamPlayer {
                    activeTimePitch.rate = brakeRate
                    activeTimePitch.pitch = Float(-1800.0 * (brakeP * brakeP))
                } else if isPlaying {
                    activeStreamingPlayer.currentItem?.audioTimePitchAlgorithm = .varispeed
                    activeStreamingPlayer.rate = brakeRate
                }
            } else {
                if !isUsingStreamPlayer {
                    activeTimePitch.rate = 1.0
                    activeTimePitch.pitch = 0
                } else if isPlaying {
                    activeStreamingPlayer.currentItem?.audioTimePitchAlgorithm = .timeDomain
                    activeStreamingPlayer.rate = 1.0
                }
            }

            if incomingIsStream {
                if isPlaying { idleStreamingPlayer.rate = 1.0 }
            } else if !isUsingStreamPlayer {
                idleTimePitch.rate = 1.0
                idleTimePitch.pitch = 0
            }
        } else if let rates, transitionDuration > 0.001 {
            let outTarget = Float(min(1.10, max(0.90, rates.sourcePlaybackRate)))
            let inTarget = Float(min(1.10, max(0.90, rates.targetPlaybackRate)))
            let rampProgress = Float(min(1.0, p / 0.6))
            let outRate = 1.0 + (outTarget - 1.0) * rampProgress
            let inRate = 1.0 + (inTarget - 1.0) * rampProgress

            if isUsingStreamPlayer {
                activeStreamingPlayer.currentItem?.audioTimePitchAlgorithm = .timeDomain
                activeStreamingPlayer.rate = isPlaying ? outRate : 0
            } else {
                activeTimePitch.rate = outRate
                activeTimePitch.pitch = 0
            }

            if incomingIsStream {
                idleStreamingPlayer.currentItem?.audioTimePitchAlgorithm = .timeDomain
                if isPlaying { idleStreamingPlayer.rate = inRate }
            } else if !isUsingStreamPlayer {
                idleTimePitch.rate = inRate
                idleTimePitch.pitch = 0
            }
        } else if isUsingStreamPlayer {
            // Subtle DJ turntable pitch bend for beat alignment
            let nudge = Float(1.0 + 0.03 * sin(p * .pi))
            activeStreamingPlayer.currentItem?.audioTimePitchAlgorithm = .timeDomain
            activeStreamingPlayer.rate = isPlaying ? nudge : 0
        }
        _ = filterCutoff

        // Top-5 fix #3: flip the metadata (title/artist) ~250 ms before the
        // engine actually completes the hand-off instead of waiting for
        // `completeTransition`, so the on-screen text lines up with the
        // perceived beat of the incoming track (previously ~300 ms late,
        // per the screen-recording analysis).
        if !metadataSwapped, let incomingTrack, transitionDuration * (1.0 - p) <= 0.25 {
            metadataSwapped = true
            metadataTrack = incomingTrack
        }

        if p >= 1.0, let incomingTrack {
            completeTransition(to: incomingTrack)
        }
    }

    private func completeTransition(to nextTrack: Track) {
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil
        transitionScheduledAt = nil
        activeTransitionPlan = nil
        isPlanningTransition = false
        planningStartedAt = nil
        flushListeningStats()
        reportWaveFinishedIfNeeded()

        let wasStream = isUsingStreamPlayer
        if wasStream {
            activeStreamingPlayer.pause()
            activeStreamingPlayer.replaceCurrentItem(with: nil)
        } else {
            let outgoingNode = activeTimePitch
            activePlayer.stop()
            activePlayer.volume = 1.0
            outgoingNode.rate = 1.0
            outgoingNode.pitch = 0
            outgoingNode.bypass = true
        }

        if nextTrack.isStream || incomingIsStream {
            if !wasStream {
                isUsingStreamPlayer = true
            }
            let oldActive = activeStreamingPlayer
            activeStreamingPlayer = idleStreamingPlayer
            idleStreamingPlayer = oldActive
            activeStreamingPlayer.volume = volume
            activeStreamingPlayer.rate = 1.0
            activeStreamingPlayer.currentItem?.audioTimePitchAlgorithm = .timeDomain
            idleStreamingPlayer.pause()
            idleStreamingPlayer.volume = 0
            timePitchA.pitch = 0
            timePitchB.pitch = 0
            timePitchA.rate = 1.0
            timePitchB.rate = 1.0
            playerA.stop()
            playerB.stop()
            applyEQ()
        } else {
            if wasStream {
                isUsingStreamPlayer = false
                streamingPlayerA.pause()
                streamingPlayerB.pause()
                if !engine.isRunning { try? engine.start() }
            }
            generation += 1
            activePlayer = idlePlayer
            activeAudioFile = incomingAudioFile
            incomingAudioFile = nil
            activePlayer.volume = volume
            applyEQ()
        }

        incomingTrack = nil
        incomingLaneReady = false
        prebufferedTrackId = nil
        plannedNextTrack = nil
        reverbA.wetDryMix = 0
        reverbB.wetDryMix = 0
        currentTrack = nextTrack
        metadataTrack = nil
        metadataSwapped = false
        streamDuration = nextTrack.duration
        anchorDate = Date()
        anchorOffset = incomingStartPosition
        pausedProgress = incomingStartPosition
        progress = incomingStartPosition
        isTransitioning = false
        transitionScheduled = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        SonivoDiagnostics.log("[AutoMix] Transition completed: now playing \(nextTrack.title)", tag: "AUTOMIX")

        if !isUsingStreamPlayer {
            releaseActiveTimePitchToUnity()
        } else {
            releaseActiveStreamRateToUnity()
        }

        lastNowPlayingSync = nil
        updateNowPlayingInfo()
        savePlaybackState()
        scheduleTransitionIfNeeded()
    }

    private func applyReverbPreset(_ name: String) {
        let preset: AVAudioUnitReverbPreset
        switch name {
        case "smallRoom": preset = .smallRoom
        case "mediumRoom": preset = .mediumRoom
        case "largeRoom": preset = .largeRoom
        case "largeRoom2": preset = .largeRoom2
        case "mediumHall": preset = .mediumHall
        case "mediumHall2": preset = .mediumHall2
        case "mediumHall3": preset = .mediumHall3
        case "largeHall": preset = .largeHall
        case "largeHall2": preset = .largeHall2
        case "mediumChamber": preset = .mediumChamber
        case "largeChamber": preset = .largeChamber
        case "cathedral": preset = .cathedral
        default: preset = .plate
        }
        reverbA.loadFactoryPreset(preset)
        reverbB.loadFactoryPreset(preset)
    }

    private func releaseActiveTimePitchToUnity() {
        rateReleaseTimer?.invalidate()
        let node = activeTimePitch
        let from = node.rate
        guard abs(from - 1.0) > 0.0005 else {
            node.rate = 1.0
            node.bypass = true
            return
        }
        let releaseStart = Date()
        let duration: TimeInterval = 4.0
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let progress = min(1, max(0, -releaseStart.timeIntervalSinceNow / duration))
                let eased = Float(progress * progress * (3 - 2 * progress))
                let value = from + (1.0 - from) * eased
                node.rate = value
                if progress >= 1 {
                    self.rateReleaseTimer?.invalidate()
                    self.rateReleaseTimer = nil
                    node.rate = 1.0
                    node.bypass = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rateReleaseTimer = timer
    }

    private func releaseActiveStreamRateToUnity() {
        rateReleaseTimer?.invalidate()
        let player = activeStreamingPlayer
        let from = player.rate
        guard abs(from - 1.0) > 0.0005, isPlaying else {
            player.rate = isPlaying ? 1.0 : 0
            return
        }
        let releaseStart = Date()
        let duration: TimeInterval = 4.0
        let tick: TimeInterval = 1.0 / 20.0
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isPlaying, self.activeStreamingPlayer === player else {
                    self.rateReleaseTimer?.invalidate()
                    self.rateReleaseTimer = nil
                    return
                }
                let progress = min(1, max(0, -releaseStart.timeIntervalSinceNow / duration))
                let eased = Float(progress * progress * (3 - 2 * progress))
                let value = from + (1.0 - from) * eased
                player.rate = value
                self.nudgePlaybackAnchor(by: (Double(value) - 1.0) * tick)
                if progress >= 1 {
                    player.currentItem?.audioTimePitchAlgorithm = .timeDomain
                    player.rate = self.isPlaying ? 1.0 : 0
                    self.rateReleaseTimer?.invalidate()
                    self.rateReleaseTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rateReleaseTimer = timer
    }

    private func cancelTransition() {
        transitionScheduled = false
        rateReleaseTimer?.invalidate()
        rateReleaseTimer = nil
        timePitchA.rate = 1.0
        timePitchA.bypass = true
        timePitchB.rate = 1.0
        timePitchB.bypass = true
        activeTransitionPlan = nil
        isPlanningTransition = false
        planningStartedAt = nil
        plannedNextTrack = nil
        incomingTrack = nil
        metadataTrack = nil
        metadataSwapped = false
        incomingIsStream = false
        incomingLaneReady = false
        transitionPausedAt = nil
        transitionScheduledAt = nil
        guard isTransitioning else { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil
        stopBeatLoop()
        idlePlayer.stop()
        idlePlayer.volume = 0
        activePlayer.volume = volume
        activeStreamingPlayer.volume = volume
        activeStreamingPlayer.rate = isPlaying ? 1.0 : 0
        idleStreamingPlayer.pause()
        idleStreamingPlayer.volume = 0
        idleStreamingPlayer.rate = 1.0
        reverbA.wetDryMix = 0
        reverbB.wetDryMix = 0
        incomingAudioFile = nil
        isTransitioning = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        applyEQ()
    }

    func setOutgoingPlaybackRate(_ rate: Float) {
        let clamped = min(1.15, max(0.85, rate))
        if isUsingStreamPlayer {
            activeStreamingPlayer.rate = clamped
        } else {
            activeTimePitch.rate = clamped
            if isLoopActive { looperTimePitch.rate = clamped }
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
            looperTimePitch.rate = 1.0
        }
    }

    func nudgePlaybackAnchor(by drift: TimeInterval) {
        anchorOffset += drift
    }

    private func handleTrackFinish() {
        guard !isTransitioning, !transitionScheduled else { return }
        flushListeningStats()
        reportWaveFinishedIfNeeded()
        progress = duration
        anchorDate = nil
        isPlaying = false
        activeTransitionPlan = nil
        plannedNextTrack = nil
        if repeatMode == .one {
            start(at: 0)
            return
        }
        if let nextTrack = peekNext(auto: true) {
            currentTrack = nextTrack
            start(at: 0)
        } else if let current = currentTrack, current.isStream, repeatMode != .one {
            Task { @MainActor in
                let wave = await YandexMusicService.shared.buildTrackWave(from: current, target: 20)
                guard self.currentTrack?.id == current.id else { return }
                let existing = Set(self.queue.map(\.id))
                let fresh = wave.filter { !existing.contains($0.id) && $0.id != current.id }
                guard !fresh.isEmpty else {
                    self.updateNowPlayingInfo()
                    return
                }
                SonivoDiagnostics.log("[AutoMix] Wave refill: +\(fresh.count) tracks after queue end", tag: "AUTOMIX")
                self.queue.append(contentsOf: fresh)
                self.currentTrack = fresh[0]
                self.start(at: 0)
            }
        } else {
            updateNowPlayingInfo()
        }
    }

    private func flushListeningStats() {
        guard let track = currentTrack, track.duration > 0 else { return }
        let listened = min(progress, track.duration)
        if progress > 5 {
            UserTasteEngine.shared.recordPlayback(
                track: track,
                listenedSeconds: listened,
                totalDuration: track.duration
            )
        }
        let pct = listened / track.duration
        if pct >= 0.75 {
            MoodRadioEngine.shared.recordFeedback(track: track, action: .listenThrough)
        } else if pct <= 0.35 && progress < 30 {
            MoodRadioEngine.shared.recordFeedback(track: track, action: .skipEarly(percent: pct))
        }
    }

    private func reportWaveSkipIfNeeded() {
        guard let track = currentTrack, track.isStream else { return }
        let ymID = Self.yandexTrackID(from: track)
        guard !ymID.isEmpty else { return }
        YandexMusicService.shared.reportSkip(trackId: ymID)
    }

    private func reportWaveFinishedIfNeeded() {
        guard let track = currentTrack, track.isStream, track.duration > 5 else { return }
        let ymID = Self.yandexTrackID(from: track)
        guard !ymID.isEmpty else { return }
        YandexMusicService.shared.reportTrackFinished(trackId: ymID, totalPlayedSeconds: track.duration)
    }

    private func effectiveQueue() -> [Track] {
        if queue.isEmpty { queue = LibraryStore.shared.tracks }
        return queue
    }

    func removeFromQueue(_ track: Track) {
        queue.removeAll { $0.id == track.id }
    }

    func appendToQueue(_ tracks: [Track]) {
        queue.append(contentsOf: tracks)
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
