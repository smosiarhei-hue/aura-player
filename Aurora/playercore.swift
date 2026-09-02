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

/// MPNowPlayingSession reports activation changes through a delegate. The
/// callbacks come from MediaPlayer, so every value is read out before hopping
/// onto the main actor.
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

    // Now Playing session: makes this app the explicit owner of the system
    // playback card, which is what allows tapping the title on the lock screen,
    // in Dynamic Island or in Control Center to open Sonivo.
    private var nowPlayingSession: MPNowPlayingSession?
    private var nowPlayingSessionObserver: NowPlayingSessionObserver?
    private var nowPlayingActivationInFlight = false
    private var lastRemoteCommand: (name: String, date: Date)?
    private var applicationIsActive = true

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

    // Third deck: bar-aligned outro loop of the outgoing track
    private let looperPlayer = AVAudioPlayerNode()
    private let looperTimePitch = AVAudioUnitTimePitch()
    private let looperEQ = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let looperReverb = AVAudioUnitReverb()
    private var loopBuffer: AVAudioPCMBuffer?
    private var isLoopActive = false

    private var activeAudioFile: AVAudioFile?
    private var incomingAudioFile: AVAudioFile?
    private var incomingTrack: Track?
    private var transitionDisplayDidSwitch = false
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
    /// True while the current plan is only a stop-gap because the DSP analysis has
    /// not finished yet. Provisional plans are rebuilt as soon as the real grid lands.
    private var planIsProvisional = false
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
        setupNowPlayingSession()
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

        // Loop deck: player -> timePitch -> EQ -> reverb -> mixer
        engine.connect(looperPlayer, to: looperTimePitch, format: nil)
        engine.connect(looperTimePitch, to: looperEQ, format: nil)
        engine.connect(looperEQ, to: looperReverb, format: nil)
        engine.connect(looperReverb, to: engine.mainMixerNode, format: nil)

        looperPlayer.volume = 0

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

    // MARK: - Now Playing Session (lock screen / Dynamic Island / Control Center)

    /// The system opens the app whose Now Playing session owns the card. Declaring
    /// info and playback state through the singletons alone is not enough, so the
    /// app registers an explicit session over its AVPlayers and asks for priority.
    private func setupNowPlayingSession() {
        let session = MPNowPlayingSession(players: [streamingPlayerA, streamingPlayerB])
        // Local files play through AVAudioEngine, which the session cannot observe.
        // Automatic publishing would therefore overwrite correct metadata with the
        // idle state of the AVPlayers, so everything is published manually instead.
        session.automaticallyPublishesNowPlayingInfo = false

        let observer = NowPlayingSessionObserver()
        session.delegate = observer
        nowPlayingSessionObserver = observer
        nowPlayingSession = session

        SonivoDiagnostics.log("[NowPlaying] Session created over 2 AVPlayers, canBecomeActive=\(session.canBecomeActive)", tag: "NOWPLAYING")
    }

    /// Requests ownership of the system playback card. Safe to call often: it is a
    /// no-op while the session is already active or a request is in flight.
    func activateNowPlayingSessionIfNeeded() {
        guard !applicationIsActive else { return }
        guard let session = nowPlayingSession else { return }
        guard !session.isActive, !nowPlayingActivationInFlight else { return }
        guard session.canBecomeActive else { return }

        nowPlayingActivationInFlight = true
        session.becomeActiveIfPossible { [weak self] didBecomeActive in
            Task { @MainActor in
                self?.nowPlayingActivationInFlight = false
                SonivoDiagnostics.log("[NowPlaying] becomeActiveIfPossible -> \(didBecomeActive)", tag: "NOWPLAYING")
            }
        }
    }

    /// Publishes metadata to the session's center and to the default one. Both are
    /// kept in sync because the AVAudioEngine path is invisible to the session.
    private func publishNowPlaying(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        let defaultCenter = MPNowPlayingInfoCenter.default()
        let sessionCenter = nowPlayingSession?.nowPlayingInfoCenter

        if applicationIsActive {
            defaultCenter.nowPlayingInfo = nil
            defaultCenter.playbackState = .stopped
            if let sessionCenter, sessionCenter !== defaultCenter {
                sessionCenter.nowPlayingInfo = nil
                sessionCenter.playbackState = .stopped
            }
            return
        }

        defaultCenter.nowPlayingInfo = info
        defaultCenter.playbackState = state
        if let sessionCenter, sessionCenter !== defaultCenter {
            sessionCenter.nowPlayingInfo = info
            sessionCenter.playbackState = state
        }
    }

    func setApplicationSceneActive(_ active: Bool) {
        guard applicationIsActive != active else { return }
        applicationIsActive = active
        if active {
            publishNowPlaying(nil, state: .stopped)
        } else {
            updateNowPlayingInfo()
        }
    }

    // MARK: - Lockscreen & Remote Commands

    /// The same handlers are installed on the shared command center and on the
    /// session's one, so a single system event must only be acted on once.
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

        // A stable per-track identity helps the system treat this as a real media
        // item, which is what makes the lock screen / Control Center card tappable.
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

        // Declaring the playback state is what makes iOS treat this app as the
        // active Now Playing app; the session on top of it is what makes the card
        // itself open the app when tapped.
        publishNowPlaying(info, state: isPlaying ? .playing : .paused)
        lastNowPlayingSync = Date()
        activateNowPlayingSessionIfNeeded()

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
                self.publishNowPlaying(current, state: self.isPlaying ? .playing : .paused)
            }
        }
    }

    /// Keeps the lock screen scrubber honest without rebuilding artwork every frame.
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
            if isLoopActive { looperPlayer.pause() }
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
            if isLoopActive { looperPlayer.play() }
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
        stopBeatLoop()
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
        planIsProvisional = false
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
        stopBeatLoop()
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
        stopBeatLoop()

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

    /// Local files are analysed directly. Streaming (Yandex) tracks have no
    /// local file, so a small quality copy is downloaded once and fed through
    /// the exact same DSP pipeline: this is what lets AutoMix pick a real
    /// bar-aligned strategy (bass-swap, beat-matched EQ, filter transition...)
    /// for streamed music instead of always falling back to a generic 14s
    /// energy blend with no beat grid.
    private func prewarmAnalysis(for track: Track) {
        guard analysisCache[track.id] == nil, !analysisRequested.contains(track.id) else { return }
        analysisRequested.insert(track.id)
        let id = track.id

        if !track.isStream, track.url.isFileURL {
            let url = track.url
            Task { [weak self] in
                let result = await TrackAnalysisService.shared.analysis(trackID: id, url: url)
                self?.finishAnalysis(result, id: id, label: url.lastPathComponent)
            }
            return
        }

        guard track.isStream || track.streamUrlString != nil else {
            analysisRequested.remove(id)
            return
        }

        let ymID = Self.yandexTrackID(from: track)
        guard !ymID.isEmpty else {
            analysisRequested.remove(id)
            return
        }

        Task { [weak self] in
            // A short download at the smallest quality is enough to extract the
            // real beat grid; actual playback keeps using the selected quality.
            guard let info = try? await YandexMusicService.shared.getStreamInfo(
                for: ymID,
                preferredQuality: .economical,
                preferredBitrate: 96
            ) else {
                self?.analysisRequested.remove(id)
                return
            }
            let result = await TrackAnalysisService.shared.analysis(trackID: id, streamURL: info.url)
            self?.finishAnalysis(result, id: id, label: "stream \(ymID)")
        }
    }

    private func finishAnalysis(_ result: TrackAnalysis?, id: UUID, label: String) {
        analysisRequested.remove(id)
        guard let result else { return }
        analysisCache[id] = result
        if let bpm = result.bpm, currentTrack?.id == id {
            AutoMixDJEngine.shared.currentBPM = bpm
        }
        SonivoDiagnostics.log("[AutoMix] Analysed \(label): BPM \(String(format: "%.1f", result.bpm ?? 0)), key \(result.musicalKey ?? "?"), downbeats \(result.downbeats.count)", tag: "AUTOMIX")
    }

    // MARK: - AutoMix DJ Transitions (offline DSP first, AI refinement when it arrives in time)

    private func scheduleTransitionIfNeeded() {
        guard transitionMode != .off, !isTransitioning, !transitionScheduled, isPlaying, let current = currentTrack else { return }
        let currentPos = isUsingStreamPlayer ? progress : liveProgress()
        let totalDur = duration
        guard totalDur > 10, let nextTrack = peekNext(auto: true) else { return }

        let remaining = totalDur - currentPos

        // Analysis is kicked off very early so the grid is ready long before the cue.
        if remaining <= 150 {
            prewarmAnalysis(for: current)
            prewarmAnalysis(for: nextTrack)
        }

        // 1. Offline plan from the real analysis. A provisional plan is never final:
        //    it is replaced the moment the analysis of both tracks lands, so a slow
        //    analysis can no longer lock the mix into a bare short fade.
        if remaining <= 90, activeTransitionPlan == nil || planIsProvisional {
            if let built = buildPlan(current: current, currentDuration: totalDur, next: nextTrack, remaining: remaining) {
                let wasProvisional = planIsProvisional
                activeTransitionPlan = built.plan
                planIsProvisional = built.provisional
                if !built.provisional && (activeTransitionPlan == nil || wasProvisional) {
                    SonivoDiagnostics.log("[AutoMix] Plan ready: \(built.plan.decision.transitionType), cue \(String(format: "%.1f", built.plan.cueTime))s, blend \(String(format: "%.1f", built.plan.leadTime))s", tag: "AUTOMIX")
                }
            }
        }

        // 2. Optional AI refinement — requested early, applied only if it returns before the cue.
        if transitionMode == .automix, remaining <= 70 {
            requestAIRefinementIfNeeded(current: current, next: nextTrack, remaining: remaining)
        }

        guard let plan = activeTransitionPlan else { return }

        // 3. Pre-buffer the incoming stream well before the cue so playback of the
        //    next track is instant when the transition actually begins.
        if remaining <= 20, prebufferedTrackId != nextTrack.id {
            prebufferUpcoming(nextTrack)
        }

        // 4. Fire the transition once the plan's cue time is reached.
        if currentPos >= plan.cueTime {
            beginTransition(to: nextTrack, plan: plan)
        }
    }
