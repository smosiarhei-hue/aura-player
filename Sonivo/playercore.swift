@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import MediaPlayer
import SwiftUI
import Darwin
import UIKit
import Observation
import StreamAudioProbe

enum AudioQuality: Int, CaseIterable, Identifiable, Sendable {
    case hiResLossless = 0
    case lossless = 1
    case hq = 2
    case auto = 3
    case economical = 4

    static let standard: AudioQuality = .hq

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

@Observable
@MainActor
final class PlayerCore {
    static let shared = PlayerCore()
    nonisolated static let bandFrequencies: [Float] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    nonisolated static let maximumEQGain: Float = 12
    nonisolated static let eqEnabledKey = "eq.enabled"
    nonisolated static let eqGainsKey = "eq.gains"

    /// Single reader for the persisted EQ curve.
    ///
    /// `PlayerCore` owns EQ state at runtime, but the AutoMix V2 / NeuroMix engines are built
    /// outside its control and used to read `UserDefaults` on their own — with `bool(forKey:)`,
    /// which answers `false` for a missing key while `PlayerCore` defaults the EQ to *on*.
    /// So one deck could play with the EQ bypassed while the UI showed it enabled. Every audio
    /// node now gets the same answer from here.
    nonisolated static func persistedEQ() -> (gains: [Float], enabled: Bool) {
        let defaults = UserDefaults.standard
        let enabled = (defaults.object(forKey: eqEnabledKey) as? Bool) ?? true
        var gains: [Float] = []
        if let data = defaults.data(forKey: eqGainsKey),
           let decoded = try? JSONDecoder().decode([Float].self, from: data) {
            gains = decoded
        }
        if !defaults.bool(forKey: "eq.octaveCurve.v2") {
            let old: [Float] = [20, 40, 60, 90, 160, 400, 1000, 2500, 6000, 16000]
            let curve = normalized(gains)
            gains = bandFrequencies.map { frequency in
                guard let upper = old.firstIndex(where: { $0 >= frequency }) else { return curve.last ?? 0 }
                guard upper > 0 else { return curve[0] }
                let lower = upper - 1
                let fraction = log(frequency / old[lower]) / log(old[upper] / old[lower])
                return curve[lower] + (curve[upper] - curve[lower]) * fraction
            }
            if let data = try? JSONEncoder().encode(gains) { defaults.set(data, forKey: eqGainsKey) }
            defaults.set(true, forKey: "eq.octaveCurve.v2")
        }
        // Upgrade only exact old factory bass curves; never overwrite a custom curve.
        if !defaults.bool(forKey: "eq.bassProfiles.v3") {
            if gains == [6, 5, 3, 1, 0, 0, 0, 0, 0, 0] {
                gains = [8, 6, 2, -2, -1, 0, 0, 0, 0, 0]
            } else if gains == [5, 4, 2, 0, -1, 0, 1, 2, 4, 4] {
                gains = [6, 4.5, 1.5, -1, -1, 0, 1, 2, 3, 3]
            }
            if let data = try? JSONEncoder().encode(gains) { defaults.set(data, forKey: eqGainsKey) }
            defaults.set(true, forKey: "eq.bassProfiles.v3")
        }
        return (normalized(gains), enabled)
    }
    // EQ now owns measured headroom. Flat/off and spatial passthrough keep unity gain.
    private static let streamHeadroomCeiling: Float = 1.0

    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var currentTrack: Track?
    private(set) var streamDuration: Double = 0
    private(set) var playError: String?
    // Internal gain for transitions and the sleep timer only. User volume belongs to iOS.
    var volume: Float = 1.0 {
        didSet {
            streamingPlayer.volume = volume * Self.streamHeadroomCeiling
            engine.mainMixerNode.outputVolume = volume
        }
    }
    var queue: [Track] = []
    var shuffle: Bool = false { didSet { defaults.set(shuffle, forKey: "player.shuffle") } }
    var repeatMode: RepeatMode = .off { didSet { defaults.set(repeatMode.rawValue, forKey: "player.repeat") } }
    var eqEnabled: Bool = true {
        didSet {
            guard eqEnabled != oldValue else { return }
            applyEQ()
            defaults.set(eqEnabled, forKey: Self.eqEnabledKey)
            // Realtime PCM EQ: never download a song or replace its player for this toggle.
        }
    }

    /// User EQ curve. The audio graph is only ever fed through `applyEQ()`, which reads
    /// this via `normalizedUserGains`, so a short or long array can never index-crash.
    var eqGains: [Float] = EQPresets.flat.gains {
        didSet {
            guard eqGains != oldValue else { return }
            let normalized = Self.normalized(eqGains)
            if normalized != eqGains {
                eqGains = normalized
                return
            }
            applyEQ()
            scheduleSaveEQ()

        }
    }

    /// Smart Headphone EQ: when enabled, EQ curve only applies to headphones/external outputs.
    /// Built-in phone speakers stay flat to prevent rattle and distortion.
    var eqHeadphonesOnly: Bool = false {
        didSet {
            guard eqHeadphonesOnly != oldValue else { return }
            defaults.set(eqHeadphonesOnly, forKey: "eq.headphonesOnly")
            applyEQ()
        }
    }

    private(set) var isHeadphonesConnected: Bool = false
    private(set) var isSpatialPlaybackActive: Bool = false

    /// Permit system headphone spatialization; the app does not synthesize Dolby Atmos.
    var spatialAudioEnabled: Bool = true {
        didSet {
            guard spatialAudioEnabled != oldValue else { return }
            defaults.set(spatialAudioEnabled, forKey: "player.spatialAudioEnabled")
            applySpatialAudioConfiguration()
        }
    }

    /// Headphone spatialization is not proof that the source contains Dolby Atmos.
    var isDolbyAtmosAvailable: Bool {
        spatialAudioEnabled && (currentCodec?.lowercased().contains("atmos") == true)
    }

    var isDolbyAtmosActive: Bool {
        isDolbyAtmosAvailable && isSpatialPlaybackActive
    }

    private var shouldApplyUserEQ: Bool {
        eqEnabled && (!eqHeadphonesOnly || isHeadphonesConnected)
    }

    var isEQEffectivelyActive: Bool {
        shouldApplyUserEQ && (!isUsingStreamPlayer || StreamBeatTap.shared.activeEQState == .ready)
    }

    var isEQPreparingNativeStream: Bool {
        shouldApplyUserEQ && isUsingStreamPlayer && StreamBeatTap.shared.activeEQState == .preparing
    }

    var eqUnavailableReason: String? {
        guard shouldApplyUserEQ, isUsingStreamPlayer else { return nil }
        switch StreamBeatTap.shared.activeEQState {
        case .spatialPassthrough: return "Dolby-поток • исходные каналы без EQ"
        case .unavailable: return "Этот поток не предоставляет PCM для EQ"
        default: return nil
        }
    }

    func updateAudioRouteState() {
        let route = AVAudioSession.sharedInstance().currentRoute
        var hpConnected = false
        var spatialActive = false
        for output in route.outputs {
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .usbAudio:
                hpConnected = true
            default:
                break
            }
            if output.isSpatialAudioEnabled {
                spatialActive = true
            }
        }
        self.isHeadphonesConnected = hpConnected
        self.isSpatialPlaybackActive = spatialActive
        applyEQ()
        applySpatialAudioConfiguration()
    }

    /// Rebuild invalidated CoreAudio objects, retaining queue/position but never auto-playing.
    func handleMediaServicesReset() {
        pause()
        cancelTransition()
        streamMigrationTask?.cancel()
        cancelSleepTimer()
        localSegmentTokens.removeAll()
        for (player, token) in streamingTimeObservers { player.removeTimeObserver(token) }
        streamingTimeObservers.removeAll()
        streamStatusObservers.removeAll()
        isStreamBuffering = false
        streamingPlayerA.replaceCurrentItem(with: nil)
        streamingPlayerB.replaceCurrentItem(with: nil)
        if spectrumTapInstalled { engine.mainMixerNode.removeTap(onBus: 0) }
        spectrumTapInstalled = false
        engine.stop()
        streamingPlayerA = AVPlayer()
        streamingPlayerB = AVPlayer()
        engine = AVAudioEngine()
        playerA = AVAudioPlayerNode()
        playerB = AVAudioPlayerNode()
        timePitchA = AVAudioUnitTimePitch()
        timePitchB = AVAudioUnitTimePitch()
        reverbA = AVAudioUnitReverb()
        reverbB = AVAudioUnitReverb()
        eqNodeA = AVAudioUnitEQ(numberOfBands: Self.bandFrequencies.count)
        eqNodeB = AVAudioUnitEQ(numberOfBands: Self.bandFrequencies.count)
        looperPlayer = AVAudioPlayerNode()
        looperTimePitch = AVAudioUnitTimePitch()
        looperEQ = AVAudioUnitEQ(numberOfBands: Self.bandFrequencies.count)
        looperReverb = AVAudioUnitReverb()
        vocalUnit = AVAudioUnitEQ(numberOfBands: 1)
        nativeEQRamp?.cancel()
        outputLimiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        activePlayer = playerA
        activeStreamingPlayer = streamingPlayerA
        idleStreamingPlayer = streamingPlayerB
        activeAudioFile = nil
        incomingAudioFile = nil
        activeLocalURL = nil
        activeStreamURL = nil
        isUsingStreamPlayer = currentTrack?.isStream == true || currentTrack?.streamUrlString != nil
        setupAudioEngine()
        setupStreamingPlayer()
        applyEQ()
        SpectrumAnalyzer.shared.reset()
        playError = "Аудиосистема iOS перезапущена. Нажмите воспроизведение."
        updateNowPlayingInfo()
    }

    func handleAudioRouteChange() {
        updateAudioRouteState()
    }

    func handleSpatialPlaybackCapabilitiesChanged() {
        updateAudioRouteState()
    }

    func applySpatialAudioConfiguration() {
        let formats: AVAudioSpatializationFormats = spatialAudioEnabled ? .monoStereoAndMultichannel : []
        if let itemA = streamingPlayerA.currentItem, itemA.allowedAudioSpatializationFormats != formats {
            itemA.allowedAudioSpatializationFormats = formats
        }
        if let itemB = streamingPlayerB.currentItem, itemB.allowedAudioSpatializationFormats != formats {
            itemB.allowedAudioSpatializationFormats = formats
        }
    }

    var transitionMode: TransitionMode = .off { didSet { defaults.set(transitionMode.rawValue, forKey: "player.transitionMode") } }
    var crossfadeDuration: Double = 3.0 { didSet { defaults.set(crossfadeDuration, forKey: "player.crossfadeDuration") } }

    private(set) var currentBitrate: Int?
    private(set) var currentCodec: String?
    var audioQuality: AudioQuality = .auto { didSet { defaults.set(audioQuality.rawValue, forKey: "player.quality") } }

    private(set) var sleepTimerMinutes: Int? = nil
    private(set) var sleepTimerRemaining: Double? = nil
    private var sleepDeadline: Date?

    private var sleepWatchdog: DispatchSourceTimer?
    private var lastPublishedSleepRemaining: Double = 0
    private let sleepTimerQueue = DispatchQueue.main

    private let defaults = UserDefaults.standard

    private var nowPlayingSession: MPNowPlayingSession?
    private var nowPlayingSessionObserver: NowPlayingSessionObserver?
    private var nowPlayingActivationInFlight = false
    private var lastRemoteCommand: (name: String, date: Date)?
    private var applicationIsActive = true

    @ObservationIgnored private var streamingPlayerA = AVPlayer()
    @ObservationIgnored private var streamingPlayerB = AVPlayer()
    private var activeStreamingPlayer: AVPlayer
    private var idleStreamingPlayer: AVPlayer
    var streamingPlayer: AVPlayer { activeStreamingPlayer }
    var usesStreamingBackend: Bool { isUsingStreamPlayer }
    var playbackRequestID: Int { generation }
    private var streamingTimeObservers: [(AVPlayer, Any)] = []
    private var didInstallStreamingNotifications = false
    private var isUsingStreamPlayer = false
    private var isPrebufferingNextStream = false
    private var prebufferedTrackId: UUID? = nil
    private var plannedNextTrack: Track? = nil
    private var incomingIsStream: Bool = false
    private var incomingLaneReady: Bool = false
    private var transitionScheduledAt: Date? = nil
    private var transitionPausedAt: Date? = nil

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var playerA = AVAudioPlayerNode()
    @ObservationIgnored private var playerB = AVAudioPlayerNode()
    private var activePlayer: AVAudioPlayerNode
    @ObservationIgnored private var timePitchA = AVAudioUnitTimePitch()
    @ObservationIgnored private var timePitchB = AVAudioUnitTimePitch()
    @ObservationIgnored private var reverbA = AVAudioUnitReverb()
    @ObservationIgnored private var reverbB = AVAudioUnitReverb()
    @ObservationIgnored private var eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    @ObservationIgnored private var eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)

    @ObservationIgnored private var looperPlayer = AVAudioPlayerNode()
    @ObservationIgnored private var looperTimePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var looperEQ = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    @ObservationIgnored private var looperReverb = AVAudioUnitReverb()
    private var loopBuffer: AVAudioPCMBuffer?
    private var isLoopActive = false

    @ObservationIgnored private var vocalUnit = AVAudioUnitEQ(numberOfBands: 1)
    private var activeStreamURL: URL?

    @ObservationIgnored private var outputLimiter = AVAudioUnitEffect(
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
    private(set) var metadataTrack: Track?
    private var metadataSwapped = false
    private var incomingStartPosition: Double = 0
    private var generation = 0
    private var localSegmentTokens: [ObjectIdentifier: UUID] = [:]
    private var activeLocalURL: URL?
    private var transitionPreparationTask: Task<Void, Never>?
    private var transitionRequestID = UUID()
    private var streamMigrationTask: Task<Void, Never>?
    private var sleepFadeTask: Task<Void, Never>?
    private var sleepFadeRequestID = UUID()
    private var qualityRequestID = UUID()
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

    var streamBufferFraction: Double = 0.0
    private(set) var isStreamBuffering = false
    @ObservationIgnored private var streamStatusObservers: [NSKeyValueObservation] = []
    private var failedPrebufferTrackId: UUID?
    private var lastPrebufferAttempt: Date?

    var displayTrack: Track? { currentTrack }

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
        removeLegacyUnboundedStreamCacheIfNeeded()
        configureSession()
        setupAudioEngine()
        setupStreamingPlayer()
        setupNowPlayingSession()
        loadSettings()
        setupRemoteCommandCenter()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func removeLegacyUnboundedStreamCacheIfNeeded() {
        let migrationKey = "storage.removed-unbounded-stream-cache.v1"

        let manager = FileManager.default
        let documents = documentsDirectoryURL()
        if let files = try? manager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where InternalAudioCache.isLegacyFileName(file.lastPathComponent) {
                try? manager.removeItem(at: file)
            }
        }

        if let temporaryFiles = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in temporaryFiles {
                let name = file.lastPathComponent
                if name.hasPrefix("ym_") || name.hasPrefix("stream_") {
                    try? manager.removeItem(at: file)
                }
            }
        }

        defaults.set(true, forKey: migrationKey)
        InternalAudioCache.prune(excluding: nil)
    }

    /// `AVAudioSession` category and activation are owned exclusively by
    /// `PlaybackAudioSessionCoordinator`. Configuring — and especially *activating* — the
    /// session here as well made two components fight over it and stole audio focus from
    /// other apps on every launch and every foreground, even with nothing playing.
    private func configureSession() {
        PlaybackAudioSessionCoordinator.shared.prepare()
    }

    /// Hands audio focus back so other apps can play again.
    /// Internal (not private) so `PlaybackAudioSessionCoordinator` can call it on backgrounding.
    func releaseAudioSessionIfIdle() {
        guard !isPlaying else { return }
        PlaybackAudioSessionCoordinator.shared.deactivateWhenIdle()
    }

    private func setupStreamingPlayer() {
        streamStatusObservers.removeAll()
        for p in [streamingPlayerA, streamingPlayerB] {
            let isPlayerA = p === streamingPlayerA
            streamStatusObservers.append(p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let source = isPlayerA ? self.streamingPlayerA : self.streamingPlayerB
                    guard source === self.activeStreamingPlayer else { return }
                    self.isStreamBuffering = self.isUsingStreamPlayer && self.isPlaying &&
                        source.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            })
            p.automaticallyWaitsToMinimizeStalling = false
            p.volume = volume * Self.streamHeadroomCeiling

            let interval = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 2400)
            let timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isUsingStreamPlayer, self.isPlaying, p === self.activeStreamingPlayer else { return }
                    self.isStreamBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    let sec = CMTimeGetSeconds(time)
                    if sec.isFinite && sec >= 0 {
                        self.progress = sec

                        if let item = self.activeStreamingPlayer.currentItem {
                            let d = CMTimeGetSeconds(item.duration)
                            if d.isFinite && d > 0 && self.streamDuration != d {
                                self.streamDuration = d
                            }
                            if let timeRange = item.loadedTimeRanges.first?.timeRangeValue {
                                let bufferEnd = CMTimeGetSeconds(timeRange.start) + CMTimeGetSeconds(timeRange.duration)
                                let total = self.duration
                                if total > 0 {
                                    self.streamBufferFraction = min(1.0, max(0.0, bufferEnd / total))
                                }
                            }
                        }

                        self.syncNowPlayingElapsedIfNeeded()
                        self.scheduleTransitionIfNeeded()
                        self.refillQueueIfNeeded()
                    }
                }
            }
            streamingTimeObservers.append((p, timeObserver))
        }
        guard !didInstallStreamingNotifications else { return }
        didInstallStreamingNotifications = true

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            let finishedItem = notification.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer, self.isPlaying else { return }
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
                guard let self, self.isUsingStreamPlayer, self.isPlaying else { return }
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

        engine.attach(vocalUnit)
        vocalUnit.bands[0].bypass = true
        engine.connect(engine.mainMixerNode, to: vocalUnit, format: nil)
        engine.attach(outputLimiter)
        engine.connect(vocalUnit, to: outputLimiter, format: nil)
        engine.connect(outputLimiter, to: engine.outputNode, format: nil)
        VocalIsolationManager.shared.attach(to: vocalUnit)

        engine.mainMixerNode.outputVolume = volume
        installSpectrumTap()
    }

    private func configureEQ(_ node: AVAudioUnitEQ) {
        for (i, band) in node.bands.enumerated() {
            band.frequency = i < PlayerCore.bandFrequencies.count ? PlayerCore.bandFrequencies[i] : 1000
            band.filterType = i == 0 ? .lowShelf : (i == node.bands.count - 1 ? .highShelf : .parametric)
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
        eqEnabled = defaults.object(forKey: Self.eqEnabledKey) as? Bool ?? true
        eqHeadphonesOnly = defaults.object(forKey: "eq.headphonesOnly") as? Bool ?? false
        spatialAudioEnabled = defaults.object(forKey: "player.spatialAudioEnabled") as? Bool ?? true

        if let modeStr = defaults.string(forKey: "player.transitionMode"),
           let mode = TransitionMode(rawValue: modeStr),
           mode != .automix {
            transitionMode = mode
        } else {
            transitionMode = .gapless
            defaults.set(TransitionMode.gapless.rawValue, forKey: "player.transitionMode")
        }

        crossfadeDuration = defaults.double(forKey: "player.crossfadeDuration")
        if crossfadeDuration <= 0 { crossfadeDuration = 3.0 }

        audioQuality = AudioQuality(rawValue: defaults.integer(forKey: "player.quality")) ?? .auto

        // Migrate the old app-volume preference: restoring it would multiply iOS volume
        // a second time. Never change the phone volume while loading player settings.
        defaults.removeObject(forKey: "player.volume")
        volume = 1.0
        engine.mainMixerNode.outputVolume = volume
        streamingPlayer.volume = volume * Self.streamHeadroomCeiling

        eqGains = Self.persistedEQ().gains
        updateAudioRouteState()
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

    private var saveEQTask: Task<Void, Never>?

    private func scheduleSaveEQ() {
        saveEQTask?.cancel()
        saveEQTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveEQ()
        }
    }

    func saveEQ() {
        saveEQTask?.cancel()
        saveEQTask = nil
        let clean = normalizedUserGains
        if let data = try? JSONEncoder().encode(clean) {
            defaults.set(data, forKey: Self.eqGainsKey)
        }
    }

    // MARK: - Single-writer EQ

    /// Per-deck dB offsets produced by AutoMix transition FX.
    ///
    /// Neither the slider UI nor the transition code touches `AVAudioUnitEQ.bands` directly:
    /// both publish their intent here and `applyEQ()` is the only writer. Previously both
    /// wrote `bands[i].gain` every tick and clobbered each other — the "EQ conflicts with
    /// the timer / something fights over the node" crash.
    private var eqOffsetA = [Float](repeating: 0, count: PlayerCore.bandFrequencies.count)
    private var eqOffsetB = [Float](repeating: 0, count: PlayerCore.bandFrequencies.count)
    private var eqOffsetLooper = [Float](repeating: 0, count: PlayerCore.bandFrequencies.count)
    private var streamMigrationInFlight = false
    private var lastStreamMigrationAttempt = Date.distantPast

    private var normalizedUserGains: [Float] { Self.normalized(eqGains) }

    /// Always exactly `bandFrequencies.count` elements — the only safe basis for indexing.
    nonisolated static func normalized(_ gains: [Float]) -> [Float] {
        let count = bandFrequencies.count
        var out = Array(gains.prefix(count)).map {
            $0.isFinite ? max(-maximumEQGain, min(maximumEQGain, $0)) : 0.0
        }
        if out.count < count { out.append(contentsOf: Array(repeating: 0, count: count - out.count)) }
        return out
    }

    /// Publishes transition FX offsets for the active/idle decks and repaints the graph.
    private func setTransitionEQOffsets(active: [Float], idle: [Float]) {
        let a = Self.normalized(active)
        let i = Self.normalized(idle)
        if activePlayer === playerA {
            eqOffsetA = a
            eqOffsetB = i
        } else {
            eqOffsetB = a
            eqOffsetA = i
        }
        applyEQ()
    }

    /// Neutral EQ again (user curve only). Called whenever a transition is aborted.
    private func resetTransitionEQOffsets() {
        let zero = [Float](repeating: 0, count: PlayerCore.bandFrequencies.count)
        eqOffsetA = zero
        eqOffsetB = zero
        applyEQ()
    }

    @ObservationIgnored private var nativeEQRamp: Task<Void, Never>?

    private func applyEQ() {
        let user = normalizedUserGains
        let on = shouldApplyUserEQ
        StreamBeatTap.shared.updateEQ(gains: user, enabled: on)
        func compose(_ offset: [Float]) -> [Float] {
            Self.normalized((0..<Self.bandFrequencies.count).map { on ? user[$0] + offset[$0] : offset[$0] })
        }
        let targets = [compose(eqOffsetA), compose(eqOffsetB), compose(eqOffsetLooper)]
        let nodes = [eqNodeA, eqNodeB, looperEQ]
        let rate = AVAudioSession.sharedInstance().sampleRate
        let headrooms = targets.map { curve in
            curve.withUnsafeBufferPointer { SonivoStreamEQPreamp($0.baseAddress!, $0.count, rate) }
        }
        nativeEQRamp?.cancel()
        let starting = nodes.map { $0.bands.map(\.gain) }
        let startingPreamp = nodes.map(\.globalGain)
        // Parameter interpolation avoids abrupt clicks on toggle, route changes or sliders.
        nativeEQRamp = Task { @MainActor [weak self] in
            for step in 1...8 {
                guard !Task.isCancelled, let self else { return }
                let fraction = Float(step) / 8
                for deck in nodes.indices {
                    let curve = zip(starting[deck], targets[deck]).map { $0 + ($1 - $0) * fraction }
                    let gain = startingPreamp[deck] + (headrooms[deck] - startingPreamp[deck]) * fraction
                    self.writeBands(nodes[deck], curve, globalGain: gain)
                }
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
    }

    private func writeBands(_ node: AVAudioUnitEQ, _ gains: [Float], globalGain: Float) {
        node.globalGain = max(-48, min(0, globalGain))
        let bands = node.bands
        let count = min(bands.count, gains.count)
        guard count > 0 else { return }
        for i in 0..<count {
            let targetGain = gains[i]
            guard targetGain.isFinite else { continue }
            let clamped = max(-PlayerCore.maximumEQGain, min(PlayerCore.maximumEQGain, targetGain))
            if abs(bands[i].gain - clamped) > 0.01 {
                bands[i].gain = clamped
            }
        }
    }

    /// Explicit vocal separation may require a local processing file. EQ never calls this.
    /// Single-flight and request-generation guarded; no automatic background download.
    func scheduleStreamMigrationIfNeeded(immediate: Bool = false) {
        guard isUsingStreamPlayer, isPlaying, !streamMigrationInFlight else { return }
        let elapsed = Date().timeIntervalSince(lastStreamMigrationAttempt)
        if !immediate && elapsed < 0.6 { return }
        guard streamMigrationTask == nil else { return }
        lastStreamMigrationAttempt = Date()
        streamMigrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.migrateStreamToAudioEngineIfNeeded()
            self.streamMigrationTask = nil
        }
    }

    private var idlePlayer: AVAudioPlayerNode { (activePlayer === playerA) ? playerB : playerA }
    private var activeTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchA : timePitchB }
    private var idleTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchB : timePitchA }
    private var activeReverb: AVAudioUnitReverb { (activePlayer === playerA) ? reverbA : reverbB }
    private var idleReverb: AVAudioUnitReverb { (activePlayer === playerA) ? reverbB : reverbA }

    private func setupNowPlayingSession() {
        SonivoDiagnostics.log("[NowPlaying] Configured MPNowPlayingInfoCenter.default()", tag: "NOWPLAYING")
    }

    func activateNowPlayingSessionIfNeeded() {
    }

    private func publishNowPlaying(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        let defaultCenter = MPNowPlayingInfoCenter.default()
        defaultCenter.nowPlayingInfo = info
        defaultCenter.playbackState = state
    }

    func setApplicationSceneActive(_ active: Bool) {
        guard applicationIsActive != active else { return }
        applicationIsActive = active
        tickSleepTimer()
        if active {
            publishNowPlaying(nil, state: .stopped)
        } else {
            updateNowPlayingInfo()
        }
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

        // When application is active in foreground, suppress Dynamic Island and lock screen
        // so that the Island does not show a redundant mini-player inside the app (like Apple Music).
        // It will smoothly expand on the Dynamic Island as soon as the user hides/leaves the app.
        guard !applicationIsActive else {
            publishNowPlaying(nil, state: .stopped)
            if let cover = track.coverURL, let url = URL(string: cover),
               LibraryStore.cachedArtworkImage(for: track) == nil,
               remoteArtworkCache[track.id] == nil {
                Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: data) else { return }
                    guard let self, self.currentTrack?.id == track.id else { return }
                    self.remoteArtworkCache[track.id] = image
                    LibraryStore.cacheArtworkImage(image, for: track)
                }
            }
            if let next = peekNext(auto: true) {
                preloadArtwork(for: next)
            }
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
                LibraryStore.cacheArtworkImage(image, for: track)
                guard !self.applicationIsActive else { return }
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
                self.publishNowPlaying(current, state: self.isPlaying ? .playing : .paused)
            }
        }

        if let next = peekNext(auto: true) {
            preloadArtwork(for: next)
        }
    }

    func preloadArtwork(for track: Track) {
        guard LibraryStore.cachedArtworkImage(for: track) == nil,
              remoteArtworkCache[track.id] == nil,
              let cover = track.coverURL,
              let url = URL(string: cover) else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            self?.remoteArtworkCache[track.id] = image
            LibraryStore.cacheArtworkImage(image, for: track)
        }
    }

    private func syncNowPlayingElapsedIfNeeded() {
        guard !applicationIsActive else { return }
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
        metadataTrack = nil
        incomingTrack = nil
        playError = nil
        streamDuration = track.duration
        cancelTransition()
        isPlaying = true
        start(at: 0)
        savePlaybackState()
    }

    func pause() {
        generation += 1
        streamMigrationTask?.cancel()
        if isTransitioning && transitionStartTime == nil { cancelTransition() }
        let streamPosition = CMTimeGetSeconds(activeStreamingPlayer.currentTime())
        pausedProgress = isUsingStreamPlayer && streamPosition.isFinite ? streamPosition : liveProgress()

        // 1. Unconditionally pause ALL streaming AVPlayer instances
        activeStreamingPlayer.pause()
        idleStreamingPlayer.pause()
        streamingPlayerA.pause()
        streamingPlayerB.pause()

        // 2. Unconditionally pause ALL AVAudioEngine player nodes
        activePlayer.pause()
        idlePlayer.pause()
        playerA.pause()
        playerB.pause()
        if isLoopActive { looperPlayer.pause() }
        if engine.isRunning { engine.pause() }

        // 3. Invalidate live timers and clear anchors
        stopTimer()
        anchorDate = nil
        progress = pausedProgress

        if isTransitioning, transitionStartTime != nil {
            transitionPausedAt = Date()
        }
        isPlaying = false
        metadataTrack = nil
        MusicHapticsManager.shared.stop()
        updateNowPlayingInfo()
        savePlaybackState()
        releaseAudioSessionIfIdle()
    }

    func resume() {
        guard !isPlaying, currentTrack != nil else { return }
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        if isUsingStreamPlayer {
            if activeStreamingPlayer.currentItem == nil {
                start(at: progress)
                return
            }
            activeStreamingPlayer.play()
            if isTransitioning {
                if incomingIsStream { idleStreamingPlayer.play() }
                else {
                    if !engine.isRunning { try? engine.start() }
                    idlePlayer.play()
                }
            }
            isPlaying = true
        } else {
            if activeAudioFile == nil {
                start(at: progress > 0 ? progress : pausedProgress)
                return
            }
            if !engine.isRunning {
                do { try engine.start() }
                catch { playError = "Не удалось запустить аудио: \(error.localizedDescription)"; return }
            }
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
            refillQueueIfNeeded()
        } else if let cur = currentTrack, repeatMode != .one {
            let requestToken = generation
            Task { @MainActor in
                let wave: [Track]
                if MoodRadioEngine.shared.isTrackWaveActive || YandexMusicService.shared.activeStationId?.hasPrefix("track:") == true {
                    wave = await MoodRadioEngine.shared.refillTrackWaveQueue(target: 20)
                } else {
                    wave = await YandexMusicService.shared.buildTrackWave(from: cur, target: 20)
                }
                guard self.generation == requestToken, self.currentTrack?.id == cur.id, self.isPlaying else { return }
                let existing = Set(self.queue.map(\.id))
                let fresh = wave.filter { !existing.contains($0.id) && $0.id != cur.id }
                if let first = fresh.first {
                    self.queue.append(contentsOf: fresh)
                    self.currentTrack = first
                    self.streamDuration = first.duration
                    self.start(at: 0)
                    self.refillQueueIfNeeded()
                } else {
                    self.start(at: 0)
                    self.currentTrack = cur
                }
            }
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
        guard seconds.isFinite else { return }
        let d = duration
        let clamped = max(0, min(seconds, d))
        progress = clamped
        SpectrumAnalyzer.shared.reset() // No pre-seek beat may reach the new timeline.

        if isUsingStreamPlayer {
            let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
            activeStreamingPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        } else {
            pausedProgress = clamped
            anchorOffset = clamped
            if isPlaying {
                start(at: clamped)
            } else if let file = activeAudioFile {
                localSegmentTokens.removeValue(forKey: ObjectIdentifier(activePlayer))
                activePlayer.stop()
                scheduleLocalSegment(file, on: activePlayer, at: clamped)
            }
        }
        lastNowPlayingSync = nil
        updateNowPlayingInfo()
    }

    func stopAndClear() {
        cancelSleepTimer()
        generation += 1
        streamMigrationTask?.cancel()
        sleepFadeRequestID = UUID()
        if sleepFadeTask != nil { volume = 1 }
        sleepFadeTask?.cancel()
        sleepFadeTask = nil
        localSegmentTokens.removeAll()
        activeLocalURL = nil
        activeStreamingPlayer.pause()
        activeStreamingPlayer.replaceCurrentItem(with: nil)
        idleStreamingPlayer.pause()
        idleStreamingPlayer.replaceCurrentItem(with: nil)
        streamingPlayerA.pause()
        streamingPlayerA.replaceCurrentItem(with: nil)
        streamingPlayerB.pause()
        streamingPlayerB.replaceCurrentItem(with: nil)
        playerA.stop()
        playerB.stop()
        stopBeatLoop()
        activeAudioFile = nil
        incomingAudioFile = nil
        currentTrack = nil
        activeStreamURL = nil
        metadataTrack = nil
        incomingTrack = nil
        metadataSwapped = false
        isPlaying = false
        progress = 0
        pausedProgress = 0
        streamDuration = 0
        anchorDate = nil
        cancelTransition()
        SpectrumAnalyzer.shared.reset()
        updateNowPlayingInfo()
        releaseAudioSessionIfIdle()
    }

    private func start(at seconds: Double) {
        cancelTransition()
        metadataTrack = nil
        incomingTrack = nil
        guard let track = currentTrack else { return }
        playError = nil
        plannedNextTrack = nil
        generation += 1
        let token = generation
        streamMigrationTask?.cancel()
        sleepFadeRequestID = UUID()
        if sleepFadeTask != nil { volume = 1 }
        sleepFadeTask?.cancel()
        sleepFadeTask = nil
        localSegmentTokens.removeAll()
        activeAudioFile = nil
        activeLocalURL = nil
        activeStreamURL = nil

        // Guaranteed audio session activation and playback intent
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        isPlaying = true

        // Immediately silence and detach any currently active audio sources
        activeStreamingPlayer.pause()
        activeStreamingPlayer.replaceCurrentItem(with: nil)
        idleStreamingPlayer.pause()
        idleStreamingPlayer.replaceCurrentItem(with: nil)
        streamingPlayerA.pause()
        streamingPlayerA.replaceCurrentItem(with: nil)
        streamingPlayerB.pause()
        streamingPlayerB.replaceCurrentItem(with: nil)
        playerA.stop()
        playerB.stop()
        stopBeatLoop()

        if let cachedURL = findLocalOrCachedAudioFile(for: track) {
            streamBufferFraction = 1.0
            startLocal(track, at: seconds, token: token, fileURL: cachedURL)
            return
        }

        if track.isStream || track.streamUrlString != nil {
            streamBufferFraction = 0.0
            startStream(track, at: seconds, token: token)
        } else {
            streamBufferFraction = 1.0
            startLocal(track, at: seconds, token: token)
        }
    }

    private func startLocal(_ track: Track, at seconds: Double, token: Int, isMigration: Bool = false, fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? track.url
        if !isMigration {
            isUsingStreamPlayer = false
            activeStreamingPlayer.pause()
            idleStreamingPlayer.pause()
        }
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

        Task { @MainActor in
            guard !Task.isCancelled, self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
            do {
                let audioFile = try AVAudioFile(forReading: resolvedURL)
                guard audioFile.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                self.activeLocalURL = resolvedURL
                self.activeAudioFile = audioFile
                self.incomingAudioFile = nil

                let ext = resolvedURL.pathExtension.lowercased()
                if ext == "flac" || ext == "alac" || ext == "wav" {
                    self.currentCodec = ext
                    self.currentBitrate = 1411
                } else if ext == "mp3" {
                    self.currentCodec = "mp3"
                    self.currentBitrate = 320
                } else if ext == "m4a" || ext == "aac" {
                    self.currentCodec = "aac"
                    self.currentBitrate = 256
                } else {
                    self.currentCodec = ext.isEmpty ? nil : ext
                    self.currentBitrate = 320
                }

                if !self.engine.isRunning {
                    try self.engine.start()
                }

                guard self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
                self.scheduleLocalSegment(audioFile, on: self.playerA, at: seconds)

                PlaybackAudioSessionCoordinator.shared.activateForPlayback()
                self.isUsingStreamPlayer = false
                self.applyEQ()
                self.activeStreamingPlayer.pause()
                self.idleStreamingPlayer.pause()
                self.streamingPlayerA.pause()
                self.streamingPlayerB.pause()
                self.streamingPlayerA.replaceCurrentItem(with: nil)
                self.streamingPlayerB.replaceCurrentItem(with: nil)

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

    private func scheduleLocalSegment(_ file: AVAudioFile, on node: AVAudioPlayerNode, at seconds: Double) {
        guard file.length > 0 else { return }
        let key = ObjectIdentifier(node)
        let isPlayerA = node === playerA
        let segmentToken = UUID()
        localSegmentTokens[key] = segmentToken
        let rate = file.processingFormat.sampleRate
        let offset = max(0, min(AVAudioFramePosition(seconds * rate), file.length - 1))
        let count = AVAudioFrameCount(min(file.length - offset, AVAudioFramePosition(UInt32.max)))
        node.scheduleSegment(file, startingFrame: offset, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Send only immutable IDs across the audio callback; resolve nodes on MainActor.
                let scheduledNode = isPlayerA ? self.playerA : self.playerB
                guard self.localSegmentTokens[key] == segmentToken,
                      ObjectIdentifier(scheduledNode) == key, self.activePlayer === scheduledNode,
                      !self.isUsingStreamPlayer, self.isPlaying else { return }
                self.handleTrackFinish()
            }
        }
    }

    private func startStream(_ track: Track, at seconds: Double, token: Int) {
        isUsingStreamPlayer = true
        if engine.isRunning {
            engine.pause()
        }
        playerA.stop()
        playerB.stop()
        stopBeatLoop()
        activeStreamingPlayer.pause()
        idleStreamingPlayer.pause()
        streamingPlayerA.pause()
        streamingPlayerB.pause()

        let url = track.url
        if url.scheme == "http" || url.scheme == "https" {
            guard self.generation == token, self.currentTrack?.id == track.id else { return }
            currentBitrate = 128
            currentCodec = "mp3"
            beginStream(url, at: seconds, token: token)
            return
        }

        if let streamStr = track.streamUrlString,
           let streamURL = URL(string: streamStr),
           streamURL.scheme == "http" || streamURL.scheme == "https" {
            guard self.generation == token, self.currentTrack?.id == track.id else { return }
            currentBitrate = 128
            currentCodec = "mp3"
            beginStream(streamURL, at: seconds, token: token)
            return
        }

        let ymID = Self.yandexTrackID(from: track)
        Task {
            do {
                let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                guard self.generation == token, self.currentTrack?.id == track.id else { return }
                self.currentBitrate = info.bitrate
                self.currentCodec = info.codec
                self.currentTrack?.streamUrlString = info.url.absoluteString
                self.activeStreamURL = info.url
                self.beginStream(info.url, at: seconds, token: token)
            } catch {
                // Secondary attempt with fallback quality (standard MP3 / HQ) if Lossless was unavailable
                if self.audioQuality != .standard {
                    do {
                        let fallbackInfo = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: .standard, preferredBitrate: 320)
                        guard self.generation == token, self.currentTrack?.id == track.id else { return }
                        self.currentBitrate = fallbackInfo.bitrate
                        self.currentCodec = fallbackInfo.codec
                        self.currentTrack?.streamUrlString = fallbackInfo.url.absoluteString
                        self.activeStreamURL = fallbackInfo.url
                        self.beginStream(fallbackInfo.url, at: seconds, token: token)
                        return
                    } catch { }
                }
                guard self.generation == token else { return }
                self.isPlaying = false
                self.transitionScheduled = false
                self.playError = "Не удалось открыть поток трека"
            }
        }
    }

    static func yandexTrackID(from track: Track) -> String {
        if let fromFile = YandexMusicService.ymId(fromFileName: track.fileName), !fromFile.isEmpty {
            return fromFile
        }
        let raw = track.streamUrlString ?? track.fileName
        let clean = raw
            .replacingOccurrences(of: "ym_", with: "")
            .replacingOccurrences(of: ".mp3", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty, !clean.hasPrefix("http") {
            return clean
        }
        let digits = track.fileName.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if digits.count >= 4 {
            return digits
        }
        return ""
    }

    func selectQuality(_ q: AudioQuality) {
        guard q != audioQuality else { return }
        audioQuality = q
        reapplyStreamQuality()
    }

    private func reapplyStreamQuality() {
        guard let track = currentTrack, track.isStream, isUsingStreamPlayer, isPlaying else { return }
        let request = UUID()
        qualityRequestID = request
        cancelTransition()
        streamMigrationTask?.cancel()
        let ymID = Self.yandexTrackID(from: track)
        guard !ymID.isEmpty, track.fileName.hasPrefix("ym_") || ymID.allSatisfy(\.isNumber) else { return }
        let pos = progress
        let token = generation
        Task {
            do {
                let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                guard self.generation == token, self.qualityRequestID == request,
                      self.currentTrack?.id == track.id, self.isUsingStreamPlayer, self.isPlaying else { return }
                self.currentBitrate = info.bitrate
                self.currentCodec = info.codec
                self.currentTrack?.streamUrlString = info.url.absoluteString
                self.activeStreamURL = info.url
                self.beginStream(info.url, at: pos, token: token)
            } catch { }
        }
    }

    private func beginStream(_ url: URL, at seconds: Double, token: Int) {
        guard self.generation == token, isPlaying else { return }
        localSegmentTokens.removeAll()
        playerA.stop()
        playerB.stop()
        stopBeatLoop()
        if engine.isRunning { engine.pause() }
        activeAudioFile = nil
        activeLocalURL = nil
        isUsingStreamPlayer = true
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        isStreamBuffering = true
        self.activeStreamURL = url
        self.currentTrack?.streamUrlString = url.absoluteString
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        item.allowedAudioSpatializationFormats = spatialAudioEnabled ? .monoStereoAndMultichannel : []
        StreamBeatTap.shared.attach(to: item)
        activeStreamingPlayer.replaceCurrentItem(with: item)
        activeStreamingPlayer.volume = volume * Self.streamHeadroomCeiling
        if seconds > 0 {
            activeStreamingPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        activeStreamingPlayer.play()
        self.isPlaying = true
        self.progress = seconds
        self.transitionScheduled = false
        self.lastNowPlayingSync = nil
        self.updateNowPlayingInfo()

        // Ordinary playback stays streaming-only. Full-file downloads happen
        // only after explicit vocal processing, never for EQ or spatial audio.
    }

    func findLocalOrCachedAudioFile(for track: Track) -> URL? {
        if !track.isStream && track.url.isFileURL && FileManager.default.fileExists(atPath: track.url.path) {
            return track.url
        }
        if let file = InternalAudioCache.fileURL(for: track.id) { return file }
        let ymID = Self.yandexTrackID(from: track)
        if !ymID.isEmpty {
            let encoded = Data(ymID.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tracks", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil),
               let file = files.first(where: { $0.lastPathComponent.hasPrefix(encoded + ".") }) {
                return file
            }
        }
        return nil
    }

    /// Migrates streaming playback from AVPlayer to AVAudioEngine so raw PCM samples can be processed in real time
    func migrateStreamToAudioEngineIfNeeded() async {
        guard isUsingStreamPlayer, isPlaying, !streamMigrationInFlight, let track = currentTrack else { return }
        streamMigrationInFlight = true
        defer { streamMigrationInFlight = false }
        let currentPos = progress
        let token = generation

        // 1. Instant zero-latency switch if already in local cache
        if let cachedURL = findLocalOrCachedAudioFile(for: track) {
            guard self.isPlaying, self.generation == token, self.currentTrack?.id == track.id else { return }
            self.startLocal(track, at: currentPos, token: token, isMigration: true, fileURL: cachedURL)
            return
        }

        // 2. Resolve stream URL reliably
        let streamURL: URL? = try? await {
            guard self.isPlaying, self.generation == token else { return nil }
            if let active = activeStreamURL { return active }
            if let str = track.streamUrlString, let u = URL(string: str) { return u }
            if let asset = activeStreamingPlayer.currentItem?.asset as? AVURLAsset { return asset.url }
            if track.url.scheme == "http" || track.url.scheme == "https" { return track.url }
            let ymID = Self.yandexTrackID(from: track)
            if !ymID.isEmpty {
                let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                guard !Task.isCancelled, self.generation == token, self.currentTrack?.id == track.id else { return nil }
                self.currentTrack?.streamUrlString = info.url.absoluteString
                self.activeStreamURL = info.url
                return info.url
            }
            return nil
        }()

        guard self.isPlaying, self.generation == token else { return }

        if let streamURL {
            do {
                let ext = streamURL.pathExtension.isEmpty ? "mp3" : streamURL.pathExtension
                let (temporaryURL, response) = try await URLSession.shared.download(from: streamURL)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try Task.checkCancellation()
                guard self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let validatedFile = try AVAudioFile(forReading: temporaryURL)
                guard validatedFile.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let localURL = try InternalAudioCache.store(temporaryURL: temporaryURL, for: track.id, fileExtension: ext)
                self.startLocal(track, at: self.progress, token: token, isMigration: true, fileURL: localURL)
            } catch {
                SonivoDiagnostics.log("[VocalIsolation] Stream migration to AVAudioEngine error: \(error)", tag: "AUDIO")
            }
        }
    }

    private func scheduleTransitionIfNeeded() {
        guard transitionMode == .crossfade, !isTransitioning, !transitionScheduled, isPlaying, let current = currentTrack else { return }

        scheduleSimpleTransition(current: current, blendDuration: max(1, crossfadeDuration))
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
        AutoMixDJEngine.shared.transitionProgress = 0

        let transitionID = UUID()
        transitionRequestID = transitionID
        let token = generation
        let nextURL = findLocalOrCachedAudioFile(for: nextTrack)
        incomingIsStream = nextURL == nil && (nextTrack.isStream || nextTrack.streamUrlString != nil)
        let targetStream = idleStreamingPlayer
        let targetNode = idlePlayer
        transitionPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.incomingIsStream {
                    let resolved: URL
                    if let direct = nextTrack.streamUrlString.flatMap(URL.init(string:)),
                       direct.scheme == "http" || direct.scheme == "https" {
                        resolved = direct
                    } else {
                        let info = try await YandexMusicService.shared.getStreamInfo(
                            for: Self.yandexTrackID(from: nextTrack), preferredQuality: self.audioQuality,
                            preferredBitrate: self.audioQuality.targetBitrate)
                        resolved = info.url
                    }
                    guard !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                          self.isPlaying, self.currentTrack?.id == current.id, self.incomingTrack?.id == nextTrack.id,
                          self.isTransitioning else { return }
                    let item = AVPlayerItem(url: resolved)
                    item.audioTimePitchAlgorithm = .timeDomain
                    item.allowedAudioSpatializationFormats = self.spatialAudioEnabled ? .monoStereoAndMultichannel : []
                    StreamBeatTap.shared.attach(to: item)
                    targetStream.replaceCurrentItem(with: item)
                    targetStream.volume = 0
                    targetStream.playImmediately(atRate: 1)
                } else {
                    let file = try AVAudioFile(forReading: nextURL ?? nextTrack.url)
                    guard file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    guard !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                          self.isPlaying, self.currentTrack?.id == current.id, self.isTransitioning else { return }
                    self.incomingAudioFile = file
                    self.scheduleLocalSegment(file, on: targetNode, at: 0)
                    targetNode.volume = 0
                    if !self.engine.isRunning { try self.engine.start() }
                    targetNode.play()
                }
                self.incomingLaneReady = true
                self.transitionStartTime = Date()
                self.startTransitionTimer()
                self.transitionPreparationTask = nil
            } catch {
                guard self.transitionRequestID == transitionID else { return }
                self.cancelTransition()
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
        AutoMixDJEngine.shared.resetDrop()
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
        guard isPlaying, let start = transitionStartTime, isTransitioning else { return }
        let elapsed = -start.timeIntervalSinceNow
        let p = min(elapsed / transitionDuration, 1.0)
        AutoMixDJEngine.shared.transitionProgress = p

        let sourceLevel: Float = Float(1.0 - p)
        let targetLevel: Float = Float(p)

        if isUsingStreamPlayer {
            activeStreamingPlayer.volume = sourceLevel * volume * Self.streamHeadroomCeiling
            activeStreamingPlayer.rate = isPlaying ? 1.0 : 0
        } else {
            activePlayer.volume = sourceLevel
        }

        if incomingIsStream {
            idleStreamingPlayer.volume = targetLevel * volume * Self.streamHeadroomCeiling
            idleStreamingPlayer.rate = isPlaying ? 1.0 : 0
        } else {
            idlePlayer.volume = targetLevel
        }

        if !metadataSwapped, let incomingTrack, transitionDuration * (1.0 - p) <= 0.25 {
            metadataSwapped = true
            metadataTrack = incomingTrack
        }

        if p >= 1.0, let incomingTrack {
            completeTransition(to: incomingTrack)
        }
    }

    // Reference 3-phase DJ Mashup streaming gain shaping specification
    private func legacyStreamingGainShaping(p: Double) -> (source: Float, target: Float) {
        var streamSourceVol: Float = Float(1.0 - p)
        var streamTargetVol: Float = Float(p)
        if p < 0.45 {
            let s = p / 0.45
            streamSourceVol = 0.75 + 0.25 * Float(cos(Double(s) * .pi * 0.5))
            streamTargetVol = 0.70 * Float(sin(Double(s) * .pi * 0.5))
        } else if p < 0.55 {
            let s = (p - 0.45) / 0.10
            streamSourceVol = 0.35 + 0.40 * Float(cos(Double(s) * .pi * 0.5))
            streamTargetVol = 0.70 + 0.20 * Float(sin(Double(s) * .pi * 0.5))
        } else {
            let s = (p - 0.55) / 0.45
            streamSourceVol = max(0.0, 0.35 * Float(cos(Double(s) * .pi * 0.5)))
            streamTargetVol = 0.90 + 0.10 * Float(sin(Double(s) * .pi * 0.5))
        }
        return (streamSourceVol, streamTargetVol)
    }

    private func completeTransition(to nextTrack: Track) {
        let nativeIncomingPosition = max(0, -(transitionStartTime ?? Date()).timeIntervalSinceNow)
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil
        transitionScheduledAt = nil
        flushListeningStats()
        reportWaveFinishedIfNeeded()

        let wasStream = isUsingStreamPlayer

        if incomingIsStream {
            if !wasStream {
                isUsingStreamPlayer = true
            }
            // Seamless swap: incoming player (already playing at full volume) continues undisturbed.
            // DO NOT reconfigure its audioTimePitchAlgorithm or rate while it's playing to prevent audio dropout/stutter!
            let outgoingPlayer = activeStreamingPlayer
            let incomingPlayer = idleStreamingPlayer
            activeStreamingPlayer = incomingPlayer
            idleStreamingPlayer = outgoingPlayer

            activeStreamingPlayer.volume = volume * Self.streamHeadroomCeiling
            if activeStreamingPlayer.rate != 1.0 && isPlaying {
                activeStreamingPlayer.rate = 1.0
            }

            // Cleanly pause and unbind the outgoing player in the background
            outgoingPlayer.pause()
            outgoingPlayer.replaceCurrentItem(with: nil)
            outgoingPlayer.volume = 0

            timePitchA.pitch = 0
            timePitchB.pitch = 0
            timePitchA.rate = 1.0
            timePitchB.rate = 1.0
            playerA.stop()
            playerB.stop()
        } else {
            if wasStream {
                isUsingStreamPlayer = false
                streamingPlayerA.pause()
                streamingPlayerB.pause()
                if !engine.isRunning { try? engine.start() }
            }
            let outgoingNode = activeTimePitch
            activePlayer.stop()
            activePlayer.volume = 1.0
            outgoingNode.rate = 1.0
            outgoingNode.pitch = 0
            outgoingNode.bypass = true

            localSegmentTokens.removeValue(forKey: ObjectIdentifier(activePlayer))
            activePlayer = idlePlayer
            activeAudioFile = incomingAudioFile
            activeLocalURL = activeAudioFile?.url
            incomingAudioFile = nil
            activePlayer.volume = 1
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

        // Sync playback progress accurately to the incoming player's actual continuous time
        let actualTime = isUsingStreamPlayer ? CMTimeGetSeconds(activeStreamingPlayer.currentTime()) : nativeIncomingPosition
        let resolvedPos = (actualTime.isFinite && actualTime >= 0) ? actualTime : incomingStartPosition
        anchorDate = Date()
        anchorOffset = resolvedPos
        pausedProgress = resolvedPos
        progress = resolvedPos

        isTransitioning = false
        transitionScheduled = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixDJEngine.shared.resetDrop()
        AutoMixDJEngine.shared.isPostMixActive = true
        SonivoDiagnostics.log("[AutoMix] Transition completed: now playing \(nextTrack.title)", tag: "AUTOMIX")

        if !isUsingStreamPlayer {
            startTimer()
            releaseActiveTimePitchToUnity()
        } else {
            stopTimer()
            activeAudioFile = nil
            activeLocalURL = nil
            localSegmentTokens.removeAll()
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
        transitionRequestID = UUID()
        transitionPreparationTask?.cancel()
        transitionPreparationTask = nil
        localSegmentTokens.removeValue(forKey: ObjectIdentifier(idlePlayer))
        transitionScheduled = false
        isTransitioning = false
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil
        transitionPausedAt = nil
        transitionScheduledAt = nil
        rateReleaseTimer?.invalidate()
        rateReleaseTimer = nil
        timePitchA.rate = 1.0
        timePitchA.bypass = true
        timePitchB.rate = 1.0
        timePitchB.bypass = true
        plannedNextTrack = nil
        incomingTrack = nil
        metadataTrack = nil
        metadataSwapped = false
        incomingIsStream = false
        incomingLaneReady = false
        failedPrebufferTrackId = nil
        lastPrebufferAttempt = nil
        stopBeatLoop()

        // Unconditionally silence and reset idle deck
        idleStreamingPlayer.pause()
        idleStreamingPlayer.replaceCurrentItem(with: nil)
        idleStreamingPlayer.volume = 0
        idleStreamingPlayer.rate = 0.0
        idlePlayer.stop()
        idlePlayer.volume = 0
        activePlayer.volume = 1
        activeStreamingPlayer.volume = volume * Self.streamHeadroomCeiling
        activeStreamingPlayer.rate = isUsingStreamPlayer && isPlaying ? 1.0 : 0
        reverbA.wetDryMix = 0
        reverbB.wetDryMix = 0
        incomingAudioFile = nil
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixDJEngine.shared.resetDrop()
        AutoMixDJEngine.shared.isPostMixActive = false
        resetTransitionEQOffsets()
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
        if isTransitioning || transitionScheduled {
            if let target = incomingTrack, (incomingLaneReady || idleStreamingPlayer.currentItem != nil || incomingAudioFile != nil) {
                SonivoDiagnostics.log("[AutoMix] Track finished during transition: completing immediately to \(target.title)", tag: "AUTOMIX")
                completeTransition(to: target)
                return
            } else {
                SonivoDiagnostics.log("[AutoMix] Track finished but incoming lane was not ready. Forcing advance to next track.", tag: "AUTOMIX")
                cancelTransition()
            }
        }
        flushListeningStats()
        reportWaveFinishedIfNeeded()
        progress = duration
        anchorDate = nil
        plannedNextTrack = nil

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Sonivo.handleTrackFinish") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        func finishBgTask() {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        if repeatMode == .one {
            start(at: 0)
            finishBgTask()
            return
        }
        if let nextTrack = peekNext(auto: true) {
            currentTrack = nextTrack
            start(at: 0)
            refillQueueIfNeeded()
            finishBgTask()
        } else if let current = currentTrack, repeatMode != .one {
            let requestToken = generation
            Task { @MainActor in
                defer { finishBgTask() }
                let wave: [Track]
                if MoodRadioEngine.shared.isTrackWaveActive || YandexMusicService.shared.activeStationId?.hasPrefix("track:") == true {
                    wave = await MoodRadioEngine.shared.refillTrackWaveQueue(target: 20)
                } else {
                    wave = await YandexMusicService.shared.buildTrackWave(from: current, target: 20)
                }
                guard self.generation == requestToken, self.currentTrack?.id == current.id, self.isPlaying else { return }
                let existing = Set(self.queue.map(\.id))
                let fresh = wave.filter { !existing.contains($0.id) && $0.id != current.id }
                guard !fresh.isEmpty else {
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                    return
                }
                SonivoDiagnostics.log("[AutoMix] Wave refill: +\(fresh.count) tracks after queue end", tag: "AUTOMIX")
                self.queue.append(contentsOf: fresh)
                self.currentTrack = fresh[0]
                self.start(at: 0)
                self.refillQueueIfNeeded()
            }
        } else {
            isPlaying = false
            updateNowPlayingInfo()
            finishBgTask()
        }
    }

    private var lastRefillCheck: Date?
    private var isRefillingWave = false

    func refillQueueIfNeeded() {
        guard !isRefillingWave, repeatMode != .one, let current = currentTrack else { return }
        let now = Date()
        if let last = lastRefillCheck, now.timeIntervalSince(last) < 4.0 { return }
        lastRefillCheck = now

        let q = effectiveQueue()
        guard let currentIndex = q.firstIndex(where: { $0.id == current.id }) else { return }
        let remainingAhead = q.count - 1 - currentIndex
        guard remainingAhead <= 5 else { return }

        isRefillingWave = true
        let seed = q.last ?? current
        Task { @MainActor [weak self] in
            defer { self?.isRefillingWave = false }
            guard let self, self.currentTrack != nil else { return }
            let ym = YandexMusicService.shared
            let rawTracks: [Track]
            if MoodRadioEngine.shared.isTrackWaveActive || ym.activeStationId?.hasPrefix("track:") == true {
                rawTracks = await MoodRadioEngine.shared.refillTrackWaveQueue(target: 25)
            } else if let station = ym.activeStationId {
                let rotorTracks = await ym.buildWaveQueue(stationId: station, target: 25)
                rawTracks = rotorTracks.map { ym.convertToTrack($0) }
            } else if let mood = MoodRadioEngine.shared.activeMood {
                let rotorTracks = await ym.buildWaveQueue(stationId: ym.waveMoodStationId, target: 25)
                rawTracks = rotorTracks.map { ym.convertToTrack($0) }
            } else {
                rawTracks = await ym.buildTrackWave(from: seed, target: 20)
            }
            let ranked = UserTasteEngine.shared.filterAndRankWave(tracks: rawTracks)
            let existing = Set(self.queue.map(\.id))
            let fresh = ranked.filter { !existing.contains($0.id) && $0.id != current.id && !UserTasteEngine.shared.isDisliked(track: $0) }
            guard !fresh.isEmpty else { return }
            SonivoDiagnostics.log("[Wave] Infinite queue refill: +\(fresh.count) tracks", tag: "WAVE")
            self.queue.append(contentsOf: fresh)
            if let next = self.peekNext(auto: true) {
                self.preloadArtwork(for: next)
            }
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

    func replaceUpcomingQueue(with tracks: [Track]) {
        if let current = currentTrack {
            var newQ = [current]
            var seen = Set([current.id])
            for t in tracks where seen.insert(t.id).inserted {
                newQ.append(t)
            }
            queue = newQ
        } else {
            queue = tracks
        }
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
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tickProgress() {
        guard isPlaying, !isUsingStreamPlayer else { return }
        progress = liveProgress()
        syncNowPlayingElapsedIfNeeded()
        scheduleTransitionIfNeeded()
        refillQueueIfNeeded()
    }

    func formatted(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    var sleepTimerFormatted: String? {
        guard let rem = sleepTimerRemaining, rem > 0 else { return nil }
        let totalSec = Int(ceil(rem))
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let seconds = totalSec % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    func setSleepTimer(minutes: Int?) {
        cancelSleepTimer()
        guard let minutes, minutes > 0 else { return }
        let deadline = Date().addingTimeInterval(Double(minutes) * 60)
        sleepDeadline = deadline
        sleepTimerMinutes = minutes
        lastPublishedSleepRemaining = Double(minutes) * 60
        sleepTimerRemaining = lastPublishedSleepRemaining
        startSleepTimerWatchdog()
        SonivoDiagnostics.log("[SleepTimer] Set sleep timer for \(minutes) min (deadline: \(deadline)).", tag: "SLEEP_TIMER")
    }

    func extendSleepTimer(byMinutes: Int) {
        guard byMinutes > 0 else { return }
        let currentRemaining = sleepTimerRemaining ?? 0
        let newTotal = currentRemaining + Double(byMinutes * 60)
        let newMinutes = max(1, Int(ceil(newTotal / 60.0)))
        setSleepTimer(minutes: newMinutes)
    }

    func cancelSleepTimer() {
        if sleepFadeTask != nil { volume = 1 }
        sleepFadeRequestID = UUID()
        sleepFadeTask?.cancel()
        sleepFadeTask = nil
        stopSleepTimerWatchdog()
        sleepDeadline = nil
        sleepTimerRemaining = nil
        sleepTimerMinutes = nil
        lastPublishedSleepRemaining = 0
    }

    /// One watchdog only, firing once per second with generous leeway. It runs on a private
    /// queue purely so it survives backgrounding; every state mutation hops to the main actor.
    private func startSleepTimerWatchdog() {
        stopSleepTimerWatchdog()
        let source = DispatchSource.makeTimerSource(queue: sleepTimerQueue)
        source.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in
            self?.tickSleepTimer()
        }
        source.resume()
        sleepWatchdog = source
    }

    private func stopSleepTimerWatchdog() {
        guard let source = sleepWatchdog else { return }
        sleepWatchdog = nil
        source.cancel()
    }

    func tickSleepTimer() {
        guard let deadline = sleepDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            triggerSleepTimerExpiry()
            return
        }
        // Publish only on real change at 1s granularity. Writing this on every tick (it used
        // to run at 60 and 120 Hz too) invalidated the whole player view on every frame.
        let rounded = ceil(remaining)
        guard abs(rounded - lastPublishedSleepRemaining) >= 0.5 else { return }
        lastPublishedSleepRemaining = rounded
        sleepTimerRemaining = remaining
    }

    private func triggerSleepTimerExpiry() {
        stopSleepTimerWatchdog()
        sleepDeadline = nil
        sleepTimerRemaining = nil
        sleepTimerMinutes = nil

        SonivoDiagnostics.log("[SleepTimer] Sleep timer reached deadline. Fading out and pausing playback.", tag: "SLEEP_TIMER")

        guard isPlaying else {
            releaseAudioSessionIfIdle()
            return
        }

        let initialVolume = volume
        let fadeSteps = 15
        let fadeDuration = 1.5
        let stepDelay = fadeDuration / Double(fadeSteps)

        let fadeGeneration = generation
        let fadeID = UUID()
        sleepFadeRequestID = fadeID
        sleepFadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.sleepFadeRequestID == fadeID {
                    self.volume = initialVolume
                    self.sleepFadeTask = nil
                }
            }
            for step in 1...fadeSteps {
                do { try await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, self.generation == fadeGeneration, self.isPlaying else { return }
                let fraction = Float(fadeSteps - step) / Float(fadeSteps)
                self.volume = max(0.0, initialVolume * fraction)
            }
            self.pause()
            self.volume = initialVolume
            // Sleep timer always ends the session: the point of the feature is to hand the
            // phone (and the audio focus) back to whatever plays next.
            self.releaseAudioSessionIfIdle()
        }
    }

    private var spectrumTapInstalled = false

    nonisolated private static func handleSpectrumTap(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Spectrum observation must not process vocal DSP a second time.
        // Vocal processing belongs exclusively to the render notify on vocalUnit.
        // AVAudioTime dates the first sample; FFT uses the first 1024 samples of this buffer.
        let rate=buffer.format.sampleRate
        let now=Date.timeIntervalSinceReferenceDate
        let sampleTime: TimeInterval? = time.isHostTimeValid && rate>0
            ? now+AVAudioTime.seconds(forHostTime: time.hostTime)-AVAudioTime.seconds(forHostTime: mach_absolute_time())+512/rate
            : nil
        SpectrumAnalyzer.ingest(buffer: buffer, sampleRate: rate,capturedAt: sampleTime)
    }

    func installSpectrumTap() {
        guard !spectrumTapInstalled else { return }
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.handleSpectrumTap)
        spectrumTapInstalled = true
    }
}
