@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import MediaPlayer
import SwiftUI
import Darwin
import UIKit
import Observation
import StreamAudioProbe
import AudioEngineCore
import MixModels
import MixPlanner

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

/// Remote callbacks may arrive off-main. Capture the advertised track under a tiny lock,
/// then validate its identity on MainActor before changing the shared library.
nonisolated private final class RemoteFavoriteSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var track: Track?
    func publish(_ value: Track?) { lock.lock(); track = value; lock.unlock() }
    func read() -> Track? { lock.lock(); defer { lock.unlock() }; return track }
}

/// Resumes a mashup-cue wait from timer / cancel without MainActor isolation
/// (nested types inside `@MainActor` PlayerCore inherit the actor and break
/// `withTaskCancellationHandler` onCancel — Build IPA 1127).
fileprivate final class MashupCueWaitBox: @unchecked Sendable {
    private var resumed = false
    private var timer: Timer?
    private var continuation: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()

    func setContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setTimer(_ timer: Timer) {
        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    nonisolated func finish(_ value: Bool) {
        lock.lock()
        let cont: CheckedContinuation<Bool, Never>?
        let t: Timer?
        if resumed {
            cont = nil
            t = nil
        } else {
            resumed = true
            cont = continuation
            continuation = nil
            t = timer
            timer = nil
        }
        lock.unlock()
        if let t {
            if Thread.isMainThread {
                t.invalidate()
            } else {
                DispatchQueue.main.async { t.invalidate() }
            }
        }
        cont?.resume(returning: value)
    }
}

/// Armed Automix handoff waiting for the musical cue on A.
/// Kept outside `PlayerCore` so the bake Task handle is not an @Observable field.
fileprivate final class PendingMashupLiveArm: @unchecked Sendable {
    let cueA: Double
    let cueB: Double
    let blend: Double
    let handoff: Double
    let transitionID: UUID
    let generation: Int
    let currentTrackID: UUID
    let inURL: URL
    let bakeTask: Task<(outgoing: URL, incoming: URL), Error>
    var prearmed: Bool
    var fired = false

    init(
        cueA: Double,
        cueB: Double,
        blend: Double,
        handoff: Double,
        transitionID: UUID,
        generation: Int,
        currentTrackID: UUID,
        inURL: URL,
        bakeTask: Task<(outgoing: URL, incoming: URL), Error>,
        prearmed: Bool
    ) {
        self.cueA = cueA
        self.cueB = cueB
        self.blend = blend
        self.handoff = handoff
        self.transitionID = transitionID
        self.generation = generation
        self.currentTrackID = currentTrackID
        self.inURL = inURL
        self.bakeTask = bakeTask
        self.prearmed = prearmed
    }
}

@Observable
@MainActor
final class PlayerCore {
    static let shared = PlayerCore()
    /// False while `shared` is still inside `init`. Logging / observers must not
    /// touch `PlayerCore.shared` until this flips — re-entering `dispatch_once` traps.
    private(set) static var isSharedReady = false
    nonisolated static let bandFrequencies: [Float] = EQGainLimits.frequencies
    nonisolated static let maximumEQGain: Float = EQGainLimits.maximum
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
        let originalArchive = defaults.data(forKey: eqGainsKey)
        if let data = defaults.data(forKey: eqGainsKey),
           let decoded = try? JSONDecoder().decode([Float].self, from: data) {
            gains = decoded
        }
        if !defaults.bool(forKey:"eq.layout.compact10") {
            if !defaults.bool(forKey:"eq.octaveCurve.v2"), gains.count == 10 {
                let old: [Float] = [20,40,60,90,160,400,1000,2500,6000,16000]
                gains = EQGainLimits.resample(gains,from:old,to:EQGainLimits.legacyFrequencies)
            }
            // Historical exact factory remaps: never overwrite a custom curve with a factory preset.
            if !defaults.bool(forKey:"eq.bassProfiles.v3"), gains.count == 10 {
                if gains == [6,5,3,1,0,0,0,0,0,0] { gains = [8,6,2,-2,-1,0,0,0,0,0] }
                else if gains == [5,4,2,0,-1,0,1,2,4,4] { gains = [6,4.5,1.5,-1,-1,0,1,2,3,3] }
            }
            if gains.count == 10 || gains.count == EQGainLimits.denseFrequencies.count {
                if defaults.data(forKey:"eq.gains.compact10.backup") == nil,
                   let original = defaults.data(forKey:eqGainsKey) { defaults.set(original,forKey:"eq.gains.compact10.backup") }
                let source = gains.count == 10 ? EQGainLimits.legacyFrequencies : EQGainLimits.denseFrequencies
                gains = EQGainLimits.resample(gains,from:source,to:EQGainLimits.compact10Frequencies)
                if let data = try? JSONEncoder().encode(gains) { defaults.set(data,forKey:eqGainsKey) }
            }
            defaults.set(true,forKey:"eq.octaveCurve.v2")
            defaults.set(true,forKey:"eq.bassProfiles.v3")
            defaults.set(true,forKey:"eq.layout.compact10")
        }
        // One-time upgrade onto the bass-shake 10-band ladder (60 Hz shelf +
        // tight 120 Hz kick). Prior ISO/compact/6-band eras keep backups.
        if !defaults.bool(forKey: EQGainLimits.previousBassShakeLayoutKey) {
            let sourceGrid: [Float]?
            if gains.count == EQGainLimits.previousBassTightFrequencies.count {
                if defaults.bool(forKey: "eq.layout.bassTight6") {
                    sourceGrid = EQGainLimits.previousBassTightFrequencies
                } else if defaults.bool(forKey: "eq.layout.reference6") {
                    sourceGrid = EQGainLimits.previousReferenceFrequencies
                } else {
                    sourceGrid = EQGainLimits.previousBassTightFrequencies
                }
            } else if gains.count == 10 {
                if defaults.bool(forKey: "eq.layout.standard10") {
                    sourceGrid = EQGainLimits.previousStandard10Frequencies
                } else if defaults.bool(forKey: "eq.layout.compact10") {
                    sourceGrid = EQGainLimits.compact10Frequencies
                } else {
                    sourceGrid = EQGainLimits.previousStandard10Frequencies
                }
            } else if gains.count == EQGainLimits.denseFrequencies.count {
                sourceGrid = EQGainLimits.denseFrequencies
            } else {
                sourceGrid = nil
            }
            if let sourceGrid {
                if defaults.data(forKey: "eq.gains.bassShake10.backup") == nil {
                    if let data = try? JSONEncoder().encode(gains) {
                        defaults.set(data, forKey: "eq.gains.bassShake10.backup")
                    } else if let originalArchive {
                        defaults.set(originalArchive, forKey: "eq.gains.bassShake10.backup")
                    }
                }
                if defaults.bool(forKey: "eq.layout.standard10"),
                   defaults.data(forKey: "eq.gains.standard10.backup") == nil,
                   let data = try? JSONEncoder().encode(gains) {
                    defaults.set(data, forKey: "eq.gains.standard10.backup")
                }
                if gains.count == EQGainLimits.previousBassTightFrequencies.count,
                   defaults.data(forKey: "eq.gains.bassTight6.backup") == nil,
                   let data = try? JSONEncoder().encode(gains) {
                    defaults.set(data, forKey: "eq.gains.bassTight6.backup")
                }
                if !defaults.bool(forKey: "eq.layout.standard10"),
                   (gains.count == EQGainLimits.compact10Frequencies.count
                    || gains.count == EQGainLimits.denseFrequencies.count),
                   defaults.data(forKey: "eq.gains.reference6.backup") == nil,
                   let originalArchive {
                    defaults.set(originalArchive, forKey: "eq.gains.reference6.backup")
                }
                gains = EQGainLimits.resample(gains, from: sourceGrid, to: EQGainLimits.previousBassShake10Frequencies)
            }
            if gains.count == EQGainLimits.previousBassShake10Frequencies.count {
                gains = EQGainLimits.previousBassShake10Frequencies.indices.map {
                    EQGainLimits.clean(gains.indices.contains($0) ? gains[$0] : 0, at: $0)
                }
            }
            if let data = try? JSONEncoder().encode(gains) {
                defaults.set(data, forKey: eqGainsKey)
                defaults.set(true, forKey: EQGainLimits.previousBassShakeLayoutKey)
                defaults.set(true, forKey: "eq.layout.standard10")
                defaults.set(true, forKey: "eq.layout.reference6")
                defaults.set(true, forKey: "eq.layout.bassTight6")
            }
        }
        // Bass-shake → classic octave centers (32 Hz–16 kHz) for the graphic fader UI.
        if !defaults.bool(forKey: EQGainLimits.layoutMarkerKey) {
            if defaults.data(forKey: "eq.gains.bassShake10.archive") == nil,
               let data = try? JSONEncoder().encode(gains) {
                defaults.set(data, forKey: "eq.gains.bassShake10.archive")
            }
            if gains.count == EQGainLimits.previousBassShake10Frequencies.count {
                gains = EQGainLimits.resample(gains, from: EQGainLimits.previousBassShake10Frequencies, to: EQGainLimits.frequencies)
            } else if gains.count == EQGainLimits.previousStandard10Frequencies.count {
                gains = EQGainLimits.resample(gains, from: EQGainLimits.previousStandard10Frequencies, to: EQGainLimits.frequencies)
            }
            gains = EQGainLimits.normalized(gains)
            if let data = try? JSONEncoder().encode(gains) {
                defaults.set(data, forKey: eqGainsKey)
                defaults.set(true, forKey: EQGainLimits.layoutMarkerKey)
                defaults.set(true, forKey: EQGainLimits.previousBassShakeLayoutKey)
            }
        }
        return (normalized(gains), enabled)
    }

    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var currentTrack: Track?
    private(set) var streamDuration: Double = 0
    private(set) var playError: String?
    @ObservationIgnored private var playbackGainState = PlaybackGainState()
    // Read-only: no persisted/app volume slider and no second multiplier of device volume.
    var volume: Float { playbackGainState.gain }
    func beginPlaybackFade(_ scope: PlaybackGainState.Scope) -> UUID {
        let id = playbackGainState.begin(scope); applyPlaybackGain(); return id
    }
    @discardableResult func setPlaybackFade(_ scope: PlaybackGainState.Scope, id: UUID, gain: Float) -> Bool {
        guard playbackGainState.update(scope, id: id, gain: gain) else { return false }
        applyPlaybackGain(); return true
    }
    func endPlaybackFade(_ scope: PlaybackGainState.Scope, id: UUID) {
        if playbackGainState.end(scope, id: id) { applyPlaybackGain() }
    }
    private func resetPlaybackFade(_ scope: PlaybackGainState.Scope) {
        playbackGainState.reset(scope); applyPlaybackGain()
    }
    private func applyPlaybackGain() {
        engine.mainMixerNode.outputVolume = volume
        var outgoing: Float = 1, incoming: Float = 0
        if isTransitioning, let start = transitionStartTime {
            let elapsed = (transitionPausedAt ?? Date()).timeIntervalSince(start)
            let gains = CrossfadeCurve.gains(progress: elapsed / max(0.001, transitionDuration))
            outgoing = gains.outgoing; incoming = gains.incoming
        }
        activeStreamingPlayer.volume = outgoing * volume
        idleStreamingPlayer.volume = incomingIsStream ? incoming * volume : 0
    }
    var queue: [Track] = [] {
        didSet {
            if Array(queue.prefix(oldValue.count).map(\.id)) != oldValue.map(\.id) { invalidateQueueContinuation() }
        }
    }
    @ObservationIgnored private var queueContinuationID = UUID()
    @ObservationIgnored private let continuationLoader = PlaybackContinuationLoader<String, Track>()
    private func invalidateQueueContinuation() {
        queueContinuationID = UUID(); continuationLoader.invalidate()
    }
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
    private(set) var isSpatialOutputSupported: Bool = false

    /// Permit system headphone spatialization; the app does not synthesize Dolby Atmos.
    var spatialAudioEnabled: Bool = true {
        didSet {
            guard spatialAudioEnabled != oldValue else { return }
            defaults.set(spatialAudioEnabled, forKey: "player.spatialAudioEnabled")
            applySpatialAudioConfiguration()
        }
    }

    /// Availability only. Fixed/head-tracked rendering remains a user choice in Control Center.
    var spatialAudioStatusText: String {
        if !spatialAudioEnabled { return "Пространственное аудио не запрашивается" }
        return isSpatialOutputSupported ? "Выход поддерживает Spatial Audio • режим выбирает iOS" : "Spatial Audio разрешено • требуется совместимый выход"
    }

    var shouldApplyUserEQ: Bool {
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
        var spatialSupported = false
        for output in route.outputs {
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .usbAudio:
                hpConnected = true
            default:
                break
            }
            if output.isSpatialAudioEnabled {
                spatialSupported = true
            }
        }
        self.isHeadphonesConnected = hpConnected
        self.isSpatialOutputSupported = spatialSupported
        applyEQ()
        applySpatialAudioConfiguration()
    }

    /// Rebuild invalidated CoreAudio objects, retaining queue/position but never auto-playing.
    func handleMediaServicesReset() {
        pause()
        playbackGainState.resetAll()
        cancelTransition()
        streamMigrationTask?.cancel()
        cancelSleepTimer()
        localSegmentTokens.removeAll()
        lyricsLocalSegments.removeAll()
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
        eqNodeA = AVAudioUnitEQ(numberOfBands: Self.bandFrequencies.count)
        eqNodeB = AVAudioUnitEQ(numberOfBands: Self.bandFrequencies.count)
        looperPlayer = AVAudioPlayerNode()
        looperTimePitch = AVAudioUnitTimePitch()
        looperEQ = AVAudioUnitEQ(numberOfBands: Self.bandFrequencies.count)
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

    var transitionMode: TransitionMode = .off {
        didSet {
            defaults.set(transitionMode.rawValue, forKey: "player.transitionMode")
            AutoMixSessionLog.shared.action(
                "mode",
                details: "\(oldValue.rawValue) → \(transitionMode.rawValue)"
            )
            AutoMixSessionLog.shared.ensureHeartbeat()
        }
    }
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
    private let remoteFavoriteSnapshot = RemoteFavoriteSnapshot()
    @ObservationIgnored private var favoriteCommandCenters: [MPRemoteCommandCenter] = []
    @ObservationIgnored private var favoritesObserver: NSObjectProtocol?
    private var applicationIsActive = true

    @ObservationIgnored private var streamingPlayerA = AVPlayer()
    @ObservationIgnored private var streamingPlayerB = AVPlayer()
    private var activeStreamingPlayer: AVPlayer
    private var idleStreamingPlayer: AVPlayer
    var streamingPlayer: AVPlayer { activeStreamingPlayer }
    var usesStreamingBackend: Bool { isUsingStreamPlayer }
    /// Read-only AutoMix session-log probes (no behavior change).
    var isTransitioningPublic: Bool { isTransitioning }
    var incomingTrackPublic: Track? { incomingTrack }
    var incomingLaneReadyPublic: Bool { incomingLaneReady }
    var mashupBakeActivePublic: Bool { mashupBakeRealIncomingURL != nil || mashupPlayingMasterBake }
    var activeDeckVolumePublic: Float { isUsingStreamPlayer ? activeStreamingPlayer.volume : activePlayer.volume }
    var idleDeckVolumePublic: Float {
        // Hybrid Automix (native A + stream B) must report the stream deck volume —
        // field log 1045 showed volB=0 while B lived on idleStreamingPlayer.
        if incomingIsStream { return idleStreamingPlayer.volume }
        if isUsingStreamPlayer { return 0 }
        return idlePlayer.volume
    }
    /// Locked Automix style rates/pitch for session-log honesty (not live accel).
    var mashupLockedRateAPublic: Float { activeMashupStyle.rateA }
    var mashupLockedRateBPublic: Float { activeMashupStyle.rateB }
    var mashupPitchCentsBPublic: Float { activeMashupStyle.pitchCentsB }
    var playbackRequestID: Int { generation }
    @ObservationIgnored private var lyricsSeekTarget: (id: UUID, track: UUID?, generation: Int, seconds: Double)?

    /// Display-only clock. AVPlayer already supplies presentation time; do not
    /// extrapolate through a buffering stall or add a second Bluetooth delay.
    var lyricsPresentationPosition: Double {
        if let pending = lyricsSeekTarget, pending.track == currentTrack?.id, pending.generation == generation {
            return pending.seconds
        }
        guard isPlaying else { return max(0, progress) }
        if isUsingStreamPlayer {
            guard activeStreamURL != nil, activeStreamingPlayer.currentItem?.status == .readyToPlay else {
                return max(0, progress)
            }
            let seconds = CMTimeGetSeconds(activeStreamingPlayer.currentTime())
            return seconds.isFinite && seconds >= 0 ? seconds : max(0, progress)
        }
        guard activeAudioFile != nil, activePlayer.isPlaying else { return max(0, progress) }
        let key = ObjectIdentifier(activePlayer)
        guard let segment = lyricsLocalSegments[key], localSegmentTokens[key] == segment.token,
              let render = activePlayer.lastRenderTime,
              let audioTime = activePlayer.playerTime(forNodeTime: render),
              let position = LyricsTimingStandard.localPosition(segmentStart: segment.start,
                  sampleTime: Double(audioTime.sampleTime), sampleRate: audioTime.sampleRate,
                  duration: duration) else { return max(0, progress) }
        return position
    }
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
    /// Musical cue on A for live Automix. Field 1077: prep Task parked on
    /// `waitUntilMashupCue` / MainActor TaskGroup and never reached bake.pending —
    /// playhead ticks fire the mix here so we do not starve into hardcut.
    @ObservationIgnored private var pendingMashupLiveArm: PendingMashupLiveArm?

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var playerA = AVAudioPlayerNode()
    @ObservationIgnored private var playerB = AVAudioPlayerNode()
    private var activePlayer: AVAudioPlayerNode
    @ObservationIgnored private var timePitchA = AVAudioUnitTimePitch()
    @ObservationIgnored private var timePitchB = AVAudioUnitTimePitch()
    @ObservationIgnored private var eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    @ObservationIgnored private var eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    /// Musical Automix MixFX on native decks (tempo echo + light plate).
    /// Not system Spatial Audio / HRTF — DualDeck owns the richer palette; this
    /// mirrors stream `SonivoMixFX` so stem/local mashups are not dry.
    @ObservationIgnored private var mixFXDelayA = AVAudioUnitDelay()
    @ObservationIgnored private var mixFXDelayB = AVAudioUnitDelay()
    @ObservationIgnored private var mixFXPlateA = AVAudioUnitReverb()
    @ObservationIgnored private var mixFXPlateB = AVAudioUnitReverb()

    @ObservationIgnored private var looperPlayer = AVAudioPlayerNode()
    @ObservationIgnored private var looperTimePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var looperEQ = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
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
    @ObservationIgnored private var cacheQualityInspections: [URL: (created: Date?, bytes: Int?, facts: PlaybackQualityFacts, preference: AudioQuality)] = [:]
    private var incomingQuality: PlaybackQualityFacts?
    private var metadataSwapped = false
    private var incomingStartPosition: Double = 0
    private var generation = 0
    private var localSegmentTokens: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var lyricsLocalSegments: [ObjectIdentifier: (token: UUID, start: Double)] = [:]
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
    /// Prevents stem-completion + timer from double-entering `completeTransition`
    /// (second pass stopped the freshly scheduled B and left playback frozen).
    private var isCompletingTransition = false
    /// After LAND, drained stem completions must not call `handleTrackFinish`
    /// (that skipped/killed the freshly started next track).
    private var suppressTrackFinishUntil: Date?
    /// After Automix LAND, ignore `next()` for a short window. Field logs showed
    /// ACTION next ~30ms after land.hardcut (syncLocal=0 → start() reload) which
    /// skipped the landed B track entirely.
    private var suppressAutomixSkipUntil: Date?
    private var transitionScheduled = false
    private var transitionStartTime: Date?
    private var transitionDuration: Double = 3.0
    private var transitionTimer: Timer?
    private var rateReleaseTimer: Timer?
    /// Per-pair algorithmic mashup style (archetype + profile cues).
    private var activeMashupStyle = MashupLiveStyle.fallback
    /// Live Automix plan (FX timeline). DualDeck ownership is off — PlayerCore executes FX.
    private var activeTransitionPlan: TransitionPlan?
    /// Phrase-loop cue for `loopBarsA` seeks on the outgoing deck.
    private var mashupPhraseLoopCueSec: Double = 0
    private var liveLoopNextBar: Double = .infinity
    /// Temp CAF from MidSideStemBaker (mashup window master). Deleted on complete/cancel.
    private var mashupBakeTempURLs: [URL] = []
    /// Real incoming file + cue when mashup plays a baked master from t=0.
    private var mashupBakeRealIncomingURL: URL?
    private var mashupBakeIncomingBaseCue: Double = 0
    /// Musical position on outgoing track A when the bake window starts playing
    /// (`cueA + bakeLag`). Stem CAF files begin at 0 — without this the chrome
    /// timeline resets to 0:00 for the whole MIXING phase.
    private var mashupBakeOutgoingBaseCue: Double = 0
    /// True while playing the offline A+B master (volumes already baked in).
    private var mashupPlayingMasterBake = false
    /// Stem bake failed or still cooking — dry decks with Automix EQ/echo/plate
    /// instead of dual full-volume stems (which muddies two dry streams).
    private var mashupBakeFailedUseCrossfade = false
    /// Outgoing track whose mix already failed. The playhead stays past the cue,
    /// so a cancel used to schedule the same bake again (fail → cancel → bake.start).
    private var mashupGiveUpTrackID: UUID?
    /// Musical cue B (mix-in). Kept separate from bake schedule offset so the
    /// Automix timeline snap stays on the real track position, not bakeLag.
    private var mashupIncomingCueSec: Double = 0
    /// Soft stream→stem mount after bake.ready (field: sudden loudness drop).
    private var mashupStemEntryStartedAt: Date?
    private var mashupStemEntryDuration: Double = 0.24
    private var mashupStemEntryFromStream = false
    /// Equal-power tail from the baked vocal into the dry file. Invalidated on skip.
    private var landOverlapTimer: Timer?
    private var landOverlapToken = UUID()

    var streamBufferFraction: Double = 0.0
    private(set) var isStreamBuffering = false
    @ObservationIgnored private var streamStatusObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var streamItemStatusObserver: NSKeyValueObservation?
    private var streamStartupTask: Task<Void, Never>?
    private var streamRecoveryAttemptedToken: Int?
    private var streamRecoveryInFlightToken: Int?
    private var failedPrebufferTrackId: UUID?
    private var lastPrebufferAttempt: Date?

    /// Artwork / title shown in the player. During AutoMix, snaps to the incoming
    /// track at the musical handoff (Apple Music Automix hard cut) while audio still blends.
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

    /// Live outgoing-deck position (never the Automix B handoff snap).
    /// Used for scrub/seek while a mashup is running — seek cancels the mix on this timeline.
    var playbackProgress: Double {
        // Hold the scrubbed target while AVPlayer is still seeking — otherwise the
        // periodic observer flashes t=0 after Automix LAND reloads a stream.
        if let pending = lyricsSeekTarget,
           pending.track == currentTrack?.id,
           pending.generation == generation {
            return pending.seconds
        }
        // Stem/master bake CAF starts at t=0; map wall-clock back onto track A's cue.
        if isTransitioning,
           mashupBakeRealIncomingURL != nil || mashupPlayingMasterBake,
           let start = transitionStartTime {
            let elapsed = max(0, (transitionPausedAt ?? Date()).timeIntervalSince(start))
            return min(max(0, mashupBakeOutgoingBaseCue + elapsed), duration)
        }
        return isUsingStreamPlayer ? max(0, progress) : liveProgress()
    }

    /// Duration of the live outgoing deck (paired with `playbackProgress`).
    var playbackDuration: Double {
        duration
    }

    /// Timeline seconds for chrome. Crossfade may still snap via metadataSwapped;
    /// Automix/Duet keep the live outgoing clock until LAND (`start(at:)` on B).
    var displayProgress: Double {
        if metadataSwapped, isTransitioning, !isMashupTransitionMode {
            return incomingDisplayPosition()
        }
        return playbackProgress
    }

    /// Duration paired with `displayProgress` / `displayTrack`.
    var displayDuration: Double {
        if metadataSwapped, isTransitioning, !isMashupTransitionMode,
           let incoming = metadataTrack ?? incomingTrack,
           incoming.duration > 0 {
            return incoming.duration
        }
        return playbackDuration
    }

    private func incomingDisplayPosition() -> Double {
        if incomingIsStream {
            let t = CMTimeGetSeconds(idleStreamingPlayer.currentTime())
            if t.isFinite, t >= 0 { return t }
        }
        let elapsed = max(0, -(transitionStartTime ?? Date()).timeIntervalSinceNow)
        // Stem/master bake: map wall-clock back onto real B (cue + bake lag + elapsed).
        if mashupBakeRealIncomingURL != nil || mashupPlayingMasterBake {
            return max(0, mashupBakeIncomingBaseCue + elapsed)
        }
        return max(0, incomingStartPosition + elapsed)
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
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: LibraryStore.tracksDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFavoriteCommandState() }
        }
        Self.isSharedReady = true
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
            p.volume = volume

            let interval = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 2400)
            let timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isUsingStreamPlayer, self.isPlaying, p === self.activeStreamingPlayer else { return }
                    self.isStreamBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    let sec = CMTimeGetSeconds(time)
                    if sec.isFinite && sec >= 0 {
                        // Ignore pre-seek samples (often t=0) while a scrub is in flight.
                        if let pending = self.lyricsSeekTarget,
                           pending.track == self.currentTrack?.id,
                           pending.generation == self.generation {
                            if abs(sec - pending.seconds) > 1.25 {
                                return
                            }
                            self.lyricsSeekTarget = nil
                        }
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

                        self.recordWavePlaybackTick()
                        self.checkpointPlaybackProgress()
                        self.syncNowPlayingElapsedIfNeeded()
                        self.firePendingMashupLiveArmIfNeeded()
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
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer, self.isPlaying else { return }
                if let failedItem, failedItem !== self.activeStreamingPlayer.currentItem {
                    return
                }
                guard let failedItem else { return }
                self.recoverStreamStartup(failedItem, token: self.generation, reason: "failed-to-play")
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

        configureEQ(eqNodeA)
        configureEQ(eqNodeB)
        configureEQ(looperEQ)
        configureTimePitch(timePitchA)
        configureTimePitch(timePitchB)
        configureTimePitch(looperTimePitch)
        configureNativeMixFX(delay: mixFXDelayA, reverb: mixFXPlateA)
        configureNativeMixFX(delay: mixFXDelayB, reverb: mixFXPlateB)

        engine.attach(mixFXDelayA)
        engine.attach(mixFXDelayB)
        engine.attach(mixFXPlateA)
        engine.attach(mixFXPlateB)

        engine.connect(playerA, to: timePitchA, format: nil)
        engine.connect(timePitchA, to: eqNodeA, format: nil)
        engine.connect(eqNodeA, to: mixFXDelayA, format: nil)
        engine.connect(mixFXDelayA, to: mixFXPlateA, format: nil)
        engine.connect(mixFXPlateA, to: engine.mainMixerNode, format: nil)

        engine.connect(playerB, to: timePitchB, format: nil)
        engine.connect(timePitchB, to: eqNodeB, format: nil)
        engine.connect(eqNodeB, to: mixFXDelayB, format: nil)
        engine.connect(mixFXDelayB, to: mixFXPlateB, format: nil)
        engine.connect(mixFXPlateB, to: engine.mainMixerNode, format: nil)

        engine.connect(looperPlayer, to: looperTimePitch, format: nil)
        engine.connect(looperTimePitch, to: looperEQ, format: nil)
        engine.connect(looperEQ, to: engine.mainMixerNode, format: nil)

        looperPlayer.volume = 0

        engine.attach(vocalUnit)
        vocalUnit.bands[0].bypass = true
        engine.connect(engine.mainMixerNode, to: vocalUnit, format: nil)
        // The limiter is not attached. engine.start() was clearing bypass, so a
        // raised band hit the limiter and the whole song got quieter.
        AudioUnitSetParameter(outputLimiter.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.040, 0)
        AudioUnitSetParameter(outputLimiter.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.080, 0)
        AudioUnitSetParameter(outputLimiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        outputLimiter.bypass = true
        engine.connect(vocalUnit, to: engine.outputNode, format: nil)
        VocalIsolationManager.shared.attach(to: vocalUnit)

        engine.mainMixerNode.outputVolume = volume
        installSpectrumTap()
    }

    private func resolvedEQFrequency(at index: Int, sampleRate: Double) -> Float {
        let rate = sampleRate > 0 ? sampleRate : AVAudioSession.sharedInstance().sampleRate
        let validRate = rate.isFinite && rate > 0 ? rate : 48000
        let nominal = Self.bandFrequencies.indices.contains(index) ? Self.bandFrequencies[index] : 1000
        return min(nominal, Float(validRate * 0.44))
    }

    private func configureEQ(_ node: AVAudioUnitEQ) {
        let sampleRate = node.inputFormat(forBus: 0).sampleRate
        for (i, band) in node.bands.enumerated() {
            band.frequency = resolvedEQFrequency(at: i, sampleRate: sampleRate)
            band.filterType = i == 0 ? .lowShelf : (i == node.bands.count - 1 ? .highShelf : .parametric)
            band.bandwidth = EQGainLimits.bandwidth(at:i)
            band.bypass = false
            band.gain = 0
        }
    }

    private func configureNativeMixFX(delay: AVAudioUnitDelay, reverb: AVAudioUnitReverb) {
        delay.delayTime = 0.375
        delay.feedback = 0
        delay.lowPassCutoff = 14_000
        delay.wetDryMix = 0
        delay.bypass = true
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 0
        reverb.bypass = true
    }

    private func configureTimePitch(_ node: AVAudioUnitTimePitch) {
        node.rate = 1.0
        node.pitch = 0
        // Max overlap → fewer TimePitch artefacts (Apple Automix quality path).
        node.overlap = 32.0
    }

    private func loadSettings() {
        shuffle = defaults.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: defaults.integer(forKey: "player.repeat")) ?? .off
        eqEnabled = defaults.object(forKey: Self.eqEnabledKey) as? Bool ?? true
        eqHeadphonesOnly = defaults.object(forKey: "eq.headphonesOnly") as? Bool ?? false
        spatialAudioEnabled = defaults.object(forKey: "player.spatialAudioEnabled") as? Bool ?? true

        if let modeStr = defaults.string(forKey: "player.transitionMode"),
           let mode = TransitionMode(rawValue: modeStr) {
            // Migrate the old disabled label if a stale raw value is still stored.
            if modeStr == "AutoMix (Отключено)" {
                transitionMode = .automix
                defaults.set(TransitionMode.automix.rawValue, forKey: "player.transitionMode")
            } else {
                transitionMode = mode
            }
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
        playbackGainState.resetAll()
        engine.mainMixerNode.outputVolume = volume
        streamingPlayer.volume = volume

        eqGains = Self.persistedEQ().gains
        updateAudioRouteState()
    }

    private var didRestorePlaybackState = false
    private var lastPlaybackCheckpoint: Date?
    private var restoredWaveStation: String?
    private var waveRecovery = WavePlaybackRecovery()
    private var isYandexWavePlayback: Bool {
        YandexMusicService.shared.activeStationId != nil || restoredWaveStation != nil
    }

    private func checkpointTrack(_ track: Track) -> Track {
        var copy = track
        // Catalog URLs expire and can contain credentials. Resolve a fresh URL on resume.
        if YandexMusicService.ymId(fromFileName: copy.fileName) != nil { copy.streamUrlString = nil }
        if copy.id == currentTrack?.id, streamDuration.isFinite, streamDuration > 0 { copy.duration = streamDuration }
        return copy
    }
    func savePlaybackState() {
        guard let track = currentTrack else {
            guard didRestorePlaybackState else { return }
            for key in ["player.lastTrack", "player.lastProgress", "player.lastQueue", "player.lastOwner", "player.lastWaveStation"] {
                defaults.removeObject(forKey: key)
            }
            return
        }
        if let data = try? JSONEncoder().encode(checkpointTrack(track)) {
            defaults.set(data, forKey: "player.lastTrack")
        }
        defaults.set(PlaybackResumePolicy.position(progress, duration: streamDuration > 0 ? streamDuration : (currentTrack?.duration ?? 0)), forKey: "player.lastProgress")
        let range = PlaybackResumePolicy.queueRange(count: queue.count, currentIndex: queue.firstIndex { $0.id == track.id })
        if !queue.isEmpty, let data = try? JSONEncoder().encode(Array(queue[range]).map(checkpointTrack)) {
            defaults.set(data, forKey: "player.lastQueue")
        } else { defaults.removeObject(forKey: "player.lastQueue") }
        if track.isStream, let uid = YandexMusicService.shared.currentUser?.uid {
            defaults.set(uid, forKey: "player.lastOwner")
        } else { defaults.removeObject(forKey: "player.lastOwner") }
        if let station = YandexMusicService.shared.activeStationId ?? restoredWaveStation {
            defaults.set(station, forKey: "player.lastWaveStation")
        } else { defaults.removeObject(forKey: "player.lastWaveStation") }
        lastPlaybackCheckpoint = Date()
    }

    private func checkpointPlaybackProgress() {
        guard currentTrack != nil, isPlaying else { return }
        let now = Date()
        guard lastPlaybackCheckpoint.map({ now.timeIntervalSince($0) >= 2 }) ?? true else { return }
        // Full metadata only at track/queue boundaries, not 60/120 times per second.
        defaults.set(PlaybackResumePolicy.position(progress, duration: streamDuration > 0 ? streamDuration : (currentTrack?.duration ?? 0)), forKey: "player.lastProgress")
        lastPlaybackCheckpoint = now
    }

    func restorePlaybackState() {
        guard !didRestorePlaybackState, !YandexMusicService.shared.isRestoringInitialAccount else { return }
        didRestorePlaybackState = true
        guard currentTrack == nil, !isPlaying,
              let data = defaults.data(forKey: "player.lastTrack"),
              let decoded = try? JSONDecoder().decode(Track.self, from: data) else { return }
        let service = YandexMusicService.shared
        if decoded.isStream {
            guard service.isUserLoggedIn, let owner = defaults.object(forKey: "player.lastOwner") as? Int,
                  owner == service.currentUser?.uid else { savePlaybackState(); return }
        } else if !FileManager.default.fileExists(atPath: decoded.url.path) {
            savePlaybackState(); return
        }
        let track = checkpointTrack(decoded)
        currentTrack = track
        progress = PlaybackResumePolicy.position(defaults.double(forKey: "player.lastProgress"), duration: track.duration)
        pausedProgress = progress; streamDuration = track.duration
        isPlaying = false
        if let qData = defaults.data(forKey: "player.lastQueue"),
           let savedQueue = try? JSONDecoder().decode([Track].self, from: qData) {
            queue = savedQueue.filter { $0.isStream ? service.isUserLoggedIn : FileManager.default.fileExists(atPath: $0.url.path) }.map(checkpointTrack)
        }
        if !queue.contains(where: { $0.id == track.id }) { queue.insert(track, at: 0) }
        restoredWaveStation = track.isStream ? defaults.string(forKey: "player.lastWaveStation") : nil
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
        EQGainLimits.normalized(gains)
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
        activeTransitionPlan = nil
        liveLoopNextBar = .infinity
        StreamBeatTap.shared.clearItemEQOverrides()
        StreamBeatTap.shared.clearItemMixFX()
        applyEQ()
    }

    /// Live FX sampler. Apple Automix is beatmatch + EQ carve + volumes — not a
    /// delay/reverb soup. Echo/plate triples A + B + wet and wrecks quality.
    @discardableResult
    private func applyLivePlanFX(progress: Double, elapsed: Double, outgoingVolume: Float) -> Float {
        let isAppleAutomix = transitionMode == .automix
            && isMashupTransitionMode
            && !activeMashupStyle.isDuet
        if isAppleAutomix {
            // Grammar: time-stretch / beat lock + ONE BASS/ONE VOCAL EQ + quiet bed → LAND.
            // Producers analyzing Apple Automix hear a high-cut and tiny air — we do that
            // with MashupLiveEQEnvelope, never with slap delay that doubles the vocal.
            clearLiveMixFX()
            return outgoingVolume
        }

        let plan = activeTransitionPlan
        let hasPlanFX = plan.map { $0.type != .none && !$0.fx.isEmpty } ?? false
        if !hasPlanFX {
            clearLiveMixFX()
            return outgoingVolume
        }
        let bpm = (plan?.tempoTargetBPM ?? 0) > 30
            ? (plan?.tempoTargetBPM ?? 120)
            : activeMashupStyle.targetBPM
        let safeBPM = bpm > 30 ? bpm : 120
        let bar = EffectAutomation.bar(atSeconds: elapsed, bpm: safeBPM)

        // Phrase-loop seeks restart the decoder and stutter the next song — keep off.
        let loopBars = 0
        _ = progress
        _ = loopBars

        var echoWet: Float = 0
        var echoFb: Float = 20
        var reverbWet: Float = 0
        var stutterIntensity: Float = 0
        if let plan, hasPlanFX {
            for event in plan.fx {
                guard event.target == .a, let value = EffectAutomation.value(for: event, atBar: bar) else { continue }
                switch event.kind {
                case .echoOut:
                    echoWet = max(echoWet, min(40, max(0, value)))
                    echoFb = min(25, event.param ?? echoFb)
                case .reverbWash:
                    reverbWet = max(reverbWet, min(28, max(0, value)))
                case .stutter:
                    stutterIntensity = max(stutterIntensity, min(1, max(0, value)))
                default:
                    break
                }
            }
        }

        let delaySec: Float = safeBPM > 0
            ? Float(min(1.0, max(0.08, 60 / Double(safeBPM) * 0.5)))
            : 0.35
        publishLiveMixFX(
            echoWet: echoWet / 75,
            echoFeedback: min(0.35, max(0, echoFb / 100)),
            delaySec: delaySec,
            reverbWet: reverbWet / 55
        )

        _ = stutterIntensity
        return outgoingVolume
    }

    private func publishLiveMixFX(echoWet: Float, echoFeedback: Float, delaySec: Float, reverbWet: Float) {
        let silent = echoWet < 0.001 && reverbWet < 0.001
        if isUsingStreamPlayer, let item = activeStreamingPlayer.currentItem {
            if silent {
                StreamBeatTap.shared.setItemMixFX(
                    for: item, echoWet: nil, echoFeedback: nil, delaySec: nil, reverbWet: nil
                )
            } else {
                StreamBeatTap.shared.setItemMixFX(
                    for: item,
                    echoWet: echoWet,
                    echoFeedback: echoFeedback,
                    delaySec: delaySec,
                    reverbWet: reverbWet
                )
            }
        }
        if incomingIsStream, let item = idleStreamingPlayer.currentItem {
            // Incoming stays dry — wash/echo live on outgoing A only.
            StreamBeatTap.shared.setItemMixFX(
                for: item, echoWet: nil, echoFeedback: nil, delaySec: nil, reverbWet: nil
            )
        }
        // Stem / local Automix plays on AVAudioEngine — stream MixFX never reaches it.
        publishNativeMixFX(
            echoWet: echoWet,
            echoFeedback: echoFeedback,
            delaySec: delaySec,
            reverbWet: reverbWet,
            silent: silent
        )
    }

    private func publishNativeMixFX(
        echoWet: Float,
        echoFeedback: Float,
        delaySec: Float,
        reverbWet: Float,
        silent: Bool
    ) {
        let outDelay = activePlayer === playerA ? mixFXDelayA : mixFXDelayB
        let outPlate = activePlayer === playerA ? mixFXPlateA : mixFXPlateB
        let idleDelay = activePlayer === playerA ? mixFXDelayB : mixFXDelayA
        let idlePlate = activePlayer === playerA ? mixFXPlateB : mixFXPlateA
        idleDelay.wetDryMix = 0
        idleDelay.feedback = 0
        idleDelay.bypass = true
        idlePlate.wetDryMix = 0
        idlePlate.bypass = true
        if silent {
            outDelay.wetDryMix = 0
            outDelay.feedback = 0
            outDelay.bypass = true
            outPlate.wetDryMix = 0
            outPlate.bypass = true
            return
        }
        outDelay.bypass = false
        outPlate.bypass = false
        outDelay.delayTime = TimeInterval(min(1.2, max(0.08, delaySec)))
        // Low feedback — high feedback slap doubles the vocal and feels like stutter.
        outDelay.feedback = min(28, max(0, echoFeedback * 40))
        outDelay.lowPassCutoff = 9_500
        // wetDryMix is 0…100 — keep the send subtle so the next song stays clean.
        outDelay.wetDryMix = min(28, max(0, echoWet * 36))
        outPlate.wetDryMix = min(22, max(0, reverbWet * 28))
    }

    private func clearLiveMixFX() {
        StreamBeatTap.shared.clearItemMixFX()
        // Bypass fully — wetDryMix=0 alone can leave a delay/plate tail on the next track.
        for delay in [mixFXDelayA, mixFXDelayB] {
            delay.wetDryMix = 0
            delay.feedback = 0
            delay.bypass = true
        }
        for plate in [mixFXPlateA, mixFXPlateB] {
            plate.wetDryMix = 0
            plate.bypass = true
        }
    }

    private func seekOutgoingPhraseLoop() {
        let cue = mashupPhraseLoopCueSec
        guard cue.isFinite, cue >= 0 else { return }
        // Never call public `seek(to:)` — it cancels the active Automix transition.
        if isUsingStreamPlayer {
            let t = CMTime(seconds: cue, preferredTimescale: 600)
            activeStreamingPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        guard let file = activeAudioFile else { return }
        localSegmentTokens.removeValue(forKey: ObjectIdentifier(activePlayer))
        activePlayer.stop()
        scheduleLocalSegment(file, on: activePlayer, at: cue)
        if isPlaying { activePlayer.play() }
        pausedProgress = cue
        anchorOffset = cue
        anchorDate = Date()
        progress = cue
    }

    /// Compose user EQ + mashup offsets. Enables the stream probe when offsets are audible
    /// even if the user EQ toggle is off (same semantics as native deck offsets).
    private func mashupComposedGains(offset: [Float]) -> (gains: [Float], enabled: Bool) {
        let user = normalizedUserGains
        let on = shouldApplyUserEQ
        let gains = Self.normalized((0..<Self.bandFrequencies.count).map {
            on ? user[$0] + offset[$0] : offset[$0]
        })
        let shaped = gains.contains { abs($0) > 0.01 }
        return (gains, on || shaped)
    }

    /// Publish mashup envelopes to stream taps and/or native EQ decks for any mix of backends.
    /// Writes immediately (no multi-hundred-ms ramp) so 30 Hz transition ticks stay click-free.
    private func applyMashupTransitionEQ(progress: Double) {
        let style = activeMashupStyle
        // Stem bake: mid-side CAF already carved — light HPF dissolve into LAND
        // (flat EQ made stem Automix feel like a plain overlay with no DJ filter).
        let shaped: (outgoing: [Float], incoming: [Float])
        if mashupBakeRealIncomingURL != nil || mashupPlayingMasterBake {
            if style.isDuet {
                resetTransitionEQOffsets()
                return
            }
            shaped = MashupLiveEQEnvelope.stemBakeOffsets(progress: progress, style: style)
        } else {
            shaped = MashupLiveEQEnvelope.offsets(progress: progress, style: style)
        }
        let activeOff = Self.normalized(shaped.outgoing)
        let idleOff = Self.normalized(shaped.incoming)
        if activePlayer === playerA {
            eqOffsetA = activeOff
            eqOffsetB = idleOff
        } else {
            eqOffsetB = activeOff
            eqOffsetA = idleOff
        }

        let out = mashupComposedGains(offset: activeOff)
        let incoming = mashupComposedGains(offset: idleOff)

        // Native decks: only touch audible engine lanes (stream-only mashup skips these).
        // Fixed curve-based headroom; no envelope limiter or kick-driven pumping.
        if !isUsingStreamPlayer {
            let node = activePlayer === playerA ? eqNodeA : eqNodeB
            let preamp = EQHeadroom.preamp(gains: out.gains, sampleRate: node.inputFormat(forBus: 0).sampleRate)
            writeBands(node, out.gains, globalGain: preamp)
            outputLimiter.bypass = true
        }
        if !incomingIsStream {
            let node = idlePlayer === playerA ? eqNodeA : eqNodeB
            let preamp = EQHeadroom.preamp(gains: incoming.gains, sampleRate: node.inputFormat(forBus: 0).sampleRate)
            writeBands(node, incoming.gains, globalGain: preamp)
            outputLimiter.bypass = true
        }

        // Streaming decks: per-item MTAudioProcessingTap EQ (Yandex / online).
        if isUsingStreamPlayer, let item = activeStreamingPlayer.currentItem {
            StreamBeatTap.shared.setItemEQOverride(for: item, gains: out.gains, enabled: out.enabled)
        }
        if incomingIsStream, let item = idleStreamingPlayer.currentItem {
            StreamBeatTap.shared.setItemEQOverride(for: item, gains: incoming.gains, enabled: incoming.enabled)
        }
    }

    @ObservationIgnored private var nativeEQRamp: Task<Void, Never>?
    @ObservationIgnored private var nativeEQWasEnabled: Bool?

    private func applyEQ() {
        let user = normalizedUserGains
        let on = shouldApplyUserEQ
        let stateChanged = nativeEQWasEnabled.map { $0 != on } ?? false
        nativeEQWasEnabled = on
        StreamBeatTap.shared.updateEQ(gains: user, enabled: on)
        // Publish only to existing experimental engines; never enable/start them here.
        AutoMixV2Runtime.existing?.applyUserEQ(gains: user, enabled: on)
        NeuroMixRuntime.existing?.applyUserEQ(gains: user, enabled: on)
        func compose(_ offset: [Float]) -> [Float] {
            Self.normalized((0..<Self.bandFrequencies.count).map { on ? user[$0] + offset[$0] : offset[$0] })
        }
        let targets = [compose(eqOffsetA), compose(eqOffsetB), compose(eqOffsetLooper)]
        let nodes = [eqNodeA, eqNodeB, looperEQ]
        nativeEQRamp?.cancel()
        let starting = nodes.map { $0.bands.map(\.gain) }
        let startingPreamp = nodes.map(\.globalGain)
        let targetPreamp = nodes.indices.map { index in
            EQHeadroom.preamp(gains: targets[index], sampleRate: nodes[index].inputFormat(forBus: 0).sampleRate)
        }
        // Fixed headroom per curve; never modulate gain from the music envelope.
        outputLimiter.bypass = true
        let bandChange = zip(starting, targets).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
        let duration = stateChanged ? 350 : max(90, min(400, Int(bandChange / 24 * 1000)))
        let steps = max(8, duration / 10)
        // New slider/toggle commands cancel the old ramp and resume at current values.
        nativeEQRamp = Task { @MainActor [weak self] in
            for step in 1...steps {
                guard !Task.isCancelled, let self else { return }
                let t = Float(step) / Float(steps)
                let fraction = t * t * (3 - 2 * t)
                for deck in nodes.indices {
                    let curve = zip(starting[deck], targets[deck]).map { $0 + ($1 - $0) * fraction }
                    let preamp = startingPreamp[deck] + (targetPreamp[deck] - startingPreamp[deck]) * fraction
                    self.writeBands(nodes[deck], curve, globalGain: preamp)
                }
                do { try await Task.sleep(for: .milliseconds(duration / steps)) } catch { return }
            }
            self?.outputLimiter.bypass = true
        }
    }

    private func writeBands(_ node: AVAudioUnitEQ, _ gains: [Float], globalGain: Float) {
        // Graphic EQ: never trim the master to "make room" for a boost.
        _ = globalGain
        node.globalGain = 0
        let bands = node.bands
        let sampleRate = node.inputFormat(forBus: 0).sampleRate
        let count = min(bands.count, gains.count)
        guard count > 0 else { return }
        for i in 0..<count {
            let frequency = resolvedEQFrequency(at: i, sampleRate: sampleRate)
            if abs(bands[i].frequency - frequency) > 0.1 { bands[i].frequency = frequency }
            let targetGain = gains[i]
            guard targetGain.isFinite else { continue }
            let clamped = EQGainLimits.clean(targetGain,at:i)
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

    private func setupNowPlayingSession() {
        SonivoDiagnostics.log("[NowPlaying] Configured MPNowPlayingInfoCenter.default()", tag: "NOWPLAYING")
    }

    func activateNowPlayingSessionIfNeeded() {
    }

    @ObservationIgnored private var ownsSystemNowPlaying = false

    func relinquishSystemPlaybackSurface() {
        publishNowPlaying(nil, state: .stopped)
        SonivoLiveActivityController.shared.endForPlaybackHandoff()
    }

    private func publishNowPlaying(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        let defaultCenter = MPNowPlayingInfoCenter.default()
        guard let info else {
            guard ownsSystemNowPlaying else { return }
            defaultCenter.nowPlayingInfo = nil
            defaultCenter.playbackState = .stopped
            ownsSystemNowPlaying = false
            return
        }
        guard PlaybackAudioSessionCoordinator.shared.allowsSystemPlaybackPublication() else {
            relinquishSystemPlaybackSurface()
            return
        }
        defaultCenter.nowPlayingInfo = info
        defaultCenter.playbackState = state
        ownsSystemNowPlaying = true
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
        favoriteCommandCenters = centers
        for center in centers {
            configureRemoteCommands(center)
        }
    }

    private func refreshFavoriteCommandState() {
        let track = currentTrack
        remoteFavoriteSnapshot.publish(track)
        let favorite = track.map { LibraryStore.shared.isTrackFavorite($0) } ?? false
        let l10n = SonivoL10n.shared
        for center in favoriteCommandCenters {
            center.likeCommand.isEnabled = track != nil
            center.likeCommand.isActive = favorite
            center.likeCommand.localizedTitle = favorite ? l10n.removeFromFavorites : l10n.addToFavorites
            center.likeCommand.localizedShortTitle = l10n.isRussian ? "Избранное" : "Favorite"
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
        commandCenter.likeCommand.isEnabled = false // Enabled once an actual track is advertised.
        commandCenter.dislikeCommand.isEnabled = false
        commandCenter.bookmarkCommand.isEnabled = false
        commandCenter.ratingCommand.isEnabled = false

        // Router replaces transport targets, not feedback. Install exactly one favorite target.
        commandCenter.likeCommand.removeTarget(nil)
        let snapshot = remoteFavoriteSnapshot
        commandCenter.likeCommand.addTarget { [weak self] event in
            guard let feedback = event as? MPFeedbackCommandEvent else { return .commandFailed }
            guard let track = snapshot.read() else { return .noSuchContent }
            let favorite = !feedback.isNegative
            Task { @MainActor [weak self] in
                guard let self, self.currentTrack?.id == track.id else { return }
                LibraryStore.shared.setTrackFavorite(track, isFavorite: favorite)
                self.refreshFavoriteCommandState()
            }
            return .success
        }

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
        refreshFavoriteCommandState()
        guard PlaybackAudioSessionCoordinator.shared.allowsSystemPlaybackPublication() else {
            relinquishSystemPlaybackSurface()
            return
        }
        SonivoLiveActivityController.shared.synchronize(track: currentTrack, playing: isPlaying,
            elapsed: isUsingStreamPlayer ? progress : liveProgress(), duration: duration)
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
                guard !self.applicationIsActive,
                      PlaybackAudioSessionCoordinator.shared.allowsSystemPlaybackPublication(),
                      self.ownsSystemNowPlaying,
                      var current = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                      current[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == track.id.uuidString else { return }
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
        guard PlaybackAudioSessionCoordinator.shared.allowsSystemPlaybackPublication() else {
            relinquishSystemPlaybackSurface()
            return
        }
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

    func play(_ track: Track, newQueue: [Track]? = nil, radio: Bool = false) {
        guard !track.isStream || YandexMusicService.shared.isUserLoggedIn else { return }
        didRestorePlaybackState = true
        invalidateQueueContinuation()
        flushListeningStats()
        reportWaveSkipIfNeeded()
        if !radio && YandexMusicService.shared.activeStationId != nil {
            YandexMusicService.shared.endStationSession()
        }
        restoredWaveStation = nil
        waveRecovery = WavePlaybackRecovery()
        if let q = newQueue, q != queue { queue = q }
        if !YandexMusicService.shared.isUserLoggedIn { queue.removeAll { $0.isStream } }
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
        AutoMixSessionLog.shared.action("pause", details: String(format: "pos=%.1f", playbackProgress))
        resetPlaybackFade(.wave)
        invalidateQueueContinuation()
        generation += 1
        streamMigrationTask?.cancel()
        if isTransitioning && transitionStartTime == nil { cancelTransition() }
        let streamPosition = CMTimeGetSeconds(activeStreamingPlayer.currentTime())
        // Prefer playbackProgress so mashup-bake MIXING keeps track A's clock on pause.
        if isUsingStreamPlayer, streamPosition.isFinite {
            pausedProgress = streamPosition
        } else {
            pausedProgress = playbackProgress
        }

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
        AutoMixSessionLog.shared.action("play", details: String(format: "pos=%.1f", playbackProgress))
        if duration > 0, progress >= duration - 0.1 { next(); return }
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
        applyPlaybackGain()
        if !isTransitioning { activePlayer.volume = 1; idlePlayer.volume = 0 }
        updateNowPlayingInfo()
        savePlaybackState()
    }

    func next() {
        if let until = suppressAutomixSkipUntil, Date() < until {
            AutoMixSessionLog.shared.event(
                "next.suppressed post-LAND until=\(String(format: "%.2f", until.timeIntervalSinceNow))s"
            )
            return
        }
        AutoMixSessionLog.shared.action(
            "next",
            details: "from=\(currentTrack?.title ?? "-") to=\(peekNext(auto: false)?.title ?? "-")"
        )
        cancelTransition()
        reportWaveSkipIfNeeded()
        if let nextTrack = peekNext(auto: false) {
            currentTrack = nextTrack
            streamDuration = nextTrack.duration
            start(at: 0)
            refillQueueIfNeeded()
        } else if let cur = currentTrack, (isYandexWavePlayback || repeatMode != .one) {
            let requestToken = generation, requestQueue = queueContinuationID
            Task { @MainActor in
                let wave = await self.loadQueueContinuation(seed:cur)
                guard self.generation == requestToken, self.queueContinuationID == requestQueue, self.currentTrack?.id == cur.id else { return }
                if let ready = self.peekNext(auto:true) {
                    self.currentTrack = ready; self.streamDuration = ready.duration
                    self.start(at:0); self.refillQueueIfNeeded(); return
                }
                let existing = Set(self.queue.map(\.id))
                let fresh = wave.filter { !existing.contains($0.id) && $0.id != cur.id && !self.waveRecovery.excludes(Self.yandexTrackID(from: $0)) }
                if let first = fresh.first {
                    self.queue.append(contentsOf: fresh)
                    self.currentTrack = first
                    self.streamDuration = first.duration
                    self.start(at: 0)
                    self.refillQueueIfNeeded()
                } else if self.isYandexWavePlayback {
                    self.pause()
                    self.playError = YandexMusicService.shared.waveError ?? "Ожидаем продолжение волны. Нажмите следующий, чтобы повторить запрос."
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
        AutoMixSessionLog.shared.action("previous", details: String(format: "pos=%.1f", playbackProgress))
        cancelTransition()
        let q = effectiveQueue()
        guard let cur = currentTrack,
              let idx = q.firstIndex(where: { $0.id == cur.id }),
              idx > 0 else {
            // Already first in queue — restart current song.
            seek(to: 0)
            return
        }
        // One swipe/tap always returns to the previous track (no Apple-style
        // "restart current if >3s" that forced a second press after Automix LAND).
        reportWaveSkipIfNeeded()
        currentTrack = q[idx - 1]
        streamDuration = q[idx - 1].duration
        start(at: 0)
    }

    func seek(to seconds: Double) {
        AutoMixSessionLog.shared.action(
            "seek",
            details: String(format: "to=%.1f from=%.1f mode=%@", seconds, playbackProgress, transitionMode.rawValue)
        )
        cancelTransition()
        guard seconds.isFinite else { return }
        let d = duration
        let clamped = max(0, min(seconds, d))
        _ = waveListening.sample(trackID: currentTrack.map { Self.yandexTrackID(from: $0) } ?? "", position: clamped, advancing: false)
        progress = clamped
        SpectrumAnalyzer.shared.reset() // No pre-seek beat may reach the new timeline.

        if isUsingStreamPlayer {
            let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
            let seekID = UUID()
            lyricsSeekTarget = (seekID, currentTrack?.id, generation, clamped)
            activeStreamingPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self, self.lyricsSeekTarget?.id == seekID else { return }
                    if finished {
                        self.progress = clamped
                        self.pausedProgress = clamped
                    }
                    self.lyricsSeekTarget = nil
                }
            }
        } else if let file = activeAudioFile {
            // After Automix LAND we already have dry B open. Reschedule in place —
            // start(at:) can reject the cache on quality and flash a cold stream at t=0.
            seekLocalFile(file, to: clamped)
        } else if let url = activeLocalURL,
                  let reopened = try? AVAudioFile(forReading: url),
                  reopened.length > 0 {
            activeAudioFile = reopened
            seekLocalFile(reopened, to: clamped)
        } else if isPlaying {
            start(at: clamped)
        } else {
            pausedProgress = clamped
            anchorOffset = clamped
            anchorDate = nil
        }
        pausedProgress = clamped
        savePlaybackState()
        lastNowPlayingSync = nil
        updateNowPlayingInfo()
    }

    /// Seek the open AVAudioFile without tearing down the LAND handoff.
    private func seekLocalFile(_ file: AVAudioFile, to seconds: Double) {
        let pos = PlaybackResumePolicy.position(seconds, duration: duration)
        localSegmentTokens.removeValue(forKey: ObjectIdentifier(activePlayer))
        activePlayer.stop()
        scheduleLocalSegment(file, on: activePlayer, at: pos)
        pausedProgress = pos
        anchorOffset = pos
        progress = pos
        if isPlaying {
            activePlayer.volume = max(activePlayer.volume, volume)
            activePlayer.play()
            anchorDate = Date()
        } else {
            anchorDate = nil
        }
    }

    func stopAndClear() {
        resetPlaybackFade(.wave)
        invalidateQueueContinuation()
        cancelSleepTimer()
        generation += 1
        streamMigrationTask?.cancel()
        sleepFadeRequestID = UUID()
        resetPlaybackFade(.sleep)
        sleepFadeTask?.cancel()
        sleepFadeTask = nil
        localSegmentTokens.removeAll()
        lyricsLocalSegments.removeAll()
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
        didRestorePlaybackState = true
        restoredWaveStation = nil
        waveRecovery = WavePlaybackRecovery()
        savePlaybackState()
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
        resetPlaybackFade(.wave)
        cancelTransition()
        metadataTrack = nil
        incomingTrack = nil
        guard let track = currentTrack else { return }
        mashupGiveUpTrackID = nil
        waveListening.reset()
        streamDuration = track.duration
        progress = PlaybackResumePolicy.position(seconds, duration: track.duration)
        pausedProgress = progress
        savePlaybackState()
        playError = nil
        plannedNextTrack = nil
        generation += 1
        let token = generation
        streamMigrationTask?.cancel()
        sleepFadeRequestID = UUID()
        resetPlaybackFade(.sleep)
        sleepFadeTask?.cancel()
        sleepFadeTask = nil
        localSegmentTokens.removeAll()
        lyricsLocalSegments.removeAll()
        activeAudioFile = nil
        activeLocalURL = nil
        activeStreamURL = nil
        currentCodec = nil
        currentBitrate = nil

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
        streamStartupTask?.cancel()
        streamItemStatusObserver = nil
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
        applyEQ()

        Task { @MainActor in
            guard !Task.isCancelled, self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
            do {
                let audioFile = try AVAudioFile(forReading: resolvedURL)
                guard audioFile.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                self.activeLocalURL = resolvedURL
                self.activeAudioFile = audioFile
                self.incomingAudioFile = nil

                let facts = LocalAudioQualityReader.read(audioFile)
                self.currentCodec = facts.codec
                self.currentBitrate = facts.bitrate

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
                guard self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
                self.activeAudioFile = nil
                if track.isStream, self.skipFailedWaveTrack() { return }
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
        lyricsLocalSegments[key] = (segmentToken, Double(offset) / rate)
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
        let account = YandexMusicService.shared.accountGeneration
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

        let ymID = Self.yandexTrackID(from: track)
        let isCatalogTrack = YandexMusicService.ymId(fromFileName: track.fileName) != nil || !ymID.isEmpty
        let url = track.url
        if !isCatalogTrack, url.scheme == "http" || url.scheme == "https" {
            guard YandexMusicService.shared.accountGeneration == account, self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
            currentBitrate = nil
            currentCodec = nil
            beginStream(url, at: seconds, token: token)
            return
        }

        if !isCatalogTrack, let streamStr = track.streamUrlString,
           let streamURL = URL(string: streamStr),
           streamURL.scheme == "http" || streamURL.scheme == "https" {
            guard YandexMusicService.shared.accountGeneration == account, self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
            currentBitrate = nil
            currentCodec = nil
            beginStream(streamURL, at: seconds, token: token)
            return
        }

        Task {
            do {
                let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                guard YandexMusicService.shared.accountGeneration == account, self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
                self.currentBitrate = info.bitrate
                self.currentCodec = info.codec
                self.currentTrack?.streamUrlString = info.url.absoluteString
                self.activeStreamURL = info.url
                self.beginStream(info.url, at: seconds, token: token)
            } catch {
                guard YandexMusicService.shared.accountGeneration == account, self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
                // standard aliases HQ; explicitly bypass signed sources for recovery.
                if !(error is CancellationError) {
                    do {
                        let fallbackInfo = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: .standard, preferredBitrate: 320, legacyOnly: true)
                        guard YandexMusicService.shared.accountGeneration == account, self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
                        self.currentBitrate = fallbackInfo.bitrate
                        self.currentCodec = fallbackInfo.codec
                        self.currentTrack?.streamUrlString = fallbackInfo.url.absoluteString
                        self.activeStreamURL = fallbackInfo.url
                        self.beginStream(fallbackInfo.url, at: seconds, token: token)
                        return
                    } catch { }
                }
                guard YandexMusicService.shared.accountGeneration == account, self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
                // Network/API unavailable: preserve existing offline playback without deleting a file.
                if let cached = self.findLocalOrCachedAudioFile(for: track, respectingQuality: false) {
                    self.startLocal(track, at: seconds, token: token, fileURL: cached)
                    return
                }
                if self.skipFailedWaveTrack() { return }
                self.isPlaying = false
                self.transitionScheduled = false
                self.playError = "Не удалось открыть поток трека"
                self.savePlaybackState()
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
        // An explicit tap also retries a previously unavailable requested quality.
        audioQuality = q
        reapplyStreamQuality()
    }

    private func reapplyStreamQuality() {
        guard let track = currentTrack, track.isStream, isPlaying else { return }
        let request = UUID()
        qualityRequestID = request
        cancelTransition()
        streamMigrationTask?.cancel()
        let ymID = Self.yandexTrackID(from: track)
        guard !ymID.isEmpty, track.fileName.hasPrefix("ym_") || ymID.allSatisfy(\.isNumber) else { return }
        let token = generation
        Task {
            do {
                let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                guard self.generation == token, self.qualityRequestID == request,
                      self.currentTrack?.id == track.id, self.isPlaying else { return }
                self.currentBitrate = info.bitrate
                self.currentCodec = info.codec
                self.currentTrack?.streamUrlString = info.url.absoluteString
                self.activeStreamURL = info.url
                self.beginStream(info.url, at: self.progress, token: token)
            } catch { }
        }
    }

    /// Protect both audible and prepared decks when decoded encraw cache is pruned.
    var protectedPlaybackURLs: Set<URL> {
        var urls = Set([activeLocalURL, activeStreamURL, incomingAudioFile?.url].compactMap { $0 })
        for player in [streamingPlayerA, streamingPlayerB] {
            if let url = (player.currentItem?.asset as? AVURLAsset)?.url { urls.insert(url) }
        }
        return urls
    }

    private func beginStream(_ url: URL, at seconds: Double, token: Int) {
        guard self.generation == token, isPlaying else { return }
        if url.isFileURL, url.pathExtension.lowercased() == "flac", let track = currentTrack {
            // Decoded encraw FLAC uses the existing native AVAudioFile/AVAudioEngine lane.
            isStreamBuffering = false
            startLocal(track, at: seconds, token: token, fileURL: url)
            return
        }
        localSegmentTokens.removeAll()
        lyricsLocalSegments.removeAll()
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
        observeStreamStartup(item, at: seconds, token: token)
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

        // Ordinary playback stays streaming-only for raw sources. Authorized encraw FLAC
        // is materialized before this point; EQ/spatial toggles never initiate a download.
    }

    /// API success is not playback success: detect initial decoder failure as well as stalls.
    private func observeStreamStartup(_ item: AVPlayerItem, at seconds: Double, token: Int) {
        streamStartupTask?.cancel()
        streamItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.recoverStreamStartup(item, token: token, reason: "item-status-failed")
            }
        }
        streamStartupTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.generation == token, self.isPlaying, self.isUsingStreamPlayer,
                  self.activeStreamingPlayer.currentItem === item else { return }
            let position = CMTimeGetSeconds(self.activeStreamingPlayer.currentTime())
            guard !position.isFinite || position <= seconds + 0.05 else { return }
            self.recoverStreamStartup(item, token: token, reason: "startup-timeout")
        }
    }

    private func recoverStreamStartup(_ failedItem: AVPlayerItem, token: Int, reason: String) {
        guard generation == token, isPlaying, isUsingStreamPlayer,
              activeStreamingPlayer.currentItem === failedItem, let track = currentTrack else { return }
        guard streamRecoveryInFlightToken != token else { return }
        let service = YandexMusicService.shared
        service.recordStreamPlaybackFailure(reason)
        guard YandexMusicService.ymId(fromFileName: track.fileName) != nil,
              streamRecoveryAttemptedToken != token else {
            failStreamStartup(); return
        }
        streamRecoveryAttemptedToken = token
        streamRecoveryInFlightToken = token
        let account = service.accountGeneration
        let position = max(0, progress.isFinite ? progress : 0)
        let id = Self.yandexTrackID(from: track)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.streamRecoveryInFlightToken == token { self.streamRecoveryInFlightToken = nil } }
            do {
                let info = try await service.getStreamInfo(for: id, preferredQuality: .hq, preferredBitrate: 320, legacyOnly: true)
                guard self.generation == token, self.currentTrack?.id == track.id,
                      service.accountGeneration == account, self.isPlaying,
                      self.activeStreamingPlayer.currentItem === failedItem else { return }
                self.currentCodec = info.codec; self.currentBitrate = info.bitrate
                self.playError = nil
                self.beginStream(info.url, at: position, token: token)
            } catch {
                guard self.generation == token, self.currentTrack?.id == track.id,
                      service.accountGeneration == account, self.isPlaying,
                      self.activeStreamingPlayer.currentItem === failedItem else { return }
                if let cached = self.findLocalOrCachedAudioFile(for: track, respectingQuality: false) {
                    self.startLocal(track, at: position, token: token, fileURL: cached)
                } else { self.failStreamStartup() }
            }
        }
    }
    private func failStreamStartup() {
        streamStartupTask?.cancel()
        activeStreamingPlayer.pause()
        if skipFailedWaveTrack() { return }
        isStreamBuffering = false; isPlaying = false; transitionScheduled = false
        playError = "Не удалось запустить аудио. Повторите попытку и отправьте диагностику качества."
    }

    private func skipFailedWaveTrack() -> Bool {
        let service = YandexMusicService.shared
        guard isPlaying, isYandexWavePlayback, service.isUserLoggedIn,
              let track = currentTrack, track.isStream else { return false }
        let id = Self.yandexTrackID(from: track)
        let station = service.activeStationId ?? restoredWaveStation ?? ""
        waveRecovery.prepare(context: service.accountGeneration.uuidString + station)
        guard waveRecovery.fail(id) else { return false }
        activeStreamingPlayer.pause(); playerA.stop(); playerB.stop()
        stopTimer(); anchorDate = nil; activeAudioFile = nil
        isStreamBuffering = false
        let seconds = waveListening.finish(trackID: id) ?? 0
        service.reportSkip(trackId: id, totalPlayedSeconds: seconds)
        SonivoDiagnostics.log("Unavailable Wave source skipped", tag: "WAVE")
        next() // Native queue order; peekNext excludes failed IDs and never wraps Wave.
        return true
    }

    private func acceptsCachedPlayback(_ url: URL, for track: Track) -> Bool {
        guard track.isStream, audioQuality == .lossless || audioQuality == .hiResLossless || audioQuality == .hq else { return true }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        let prior = cacheQualityInspections[url]
        let facts: PlaybackQualityFacts
        if let prior, prior.created == values?.creationDate, prior.bytes == values?.fileSize {
            facts = prior.facts
        } else {
            guard let file = try? AVAudioFile(forReading: url) else { return false }
            facts = LocalAudioQualityReader.read(file)
        }
        let accepted = facts.isLossless || (audioQuality == .hq && (facts.bitrate ?? 0) >= 256)
        if prior == nil || prior?.preference != audioQuality || prior?.facts != facts {
            YandexMusicService.shared.recordCachedQuality(accepted: accepted, facts: facts)
        }
        if cacheQualityInspections.count > 32 { cacheQualityInspections.removeAll() }
        cacheQualityInspections[url] = (values?.creationDate, values?.fileSize, facts, audioQuality)
        return accepted
    }

    func findLocalOrCachedAudioFile(for track: Track, respectingQuality: Bool = true) -> URL? {
        if !track.isStream && track.url.isFileURL && FileManager.default.fileExists(atPath: track.url.path) {
            return track.url
        }
        if let file = InternalAudioCache.fileURL(for: track.id),
           !respectingQuality || acceptsCachedPlayback(file, for: track) { return file }
        let ymID = Self.yandexTrackID(from: track)
        if !ymID.isEmpty {
            let encoded = Data(ymID.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tracks", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil) {
                for file in files.filter({ $0.lastPathComponent.hasPrefix(encoded + ".") }) {
                    if !respectingQuality || acceptsCachedPlayback(file, for: track) { return file }
                }
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
                if streamURL.isFileURL {
                    let validated = try AVAudioFile(forReading: streamURL)
                    guard validated.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    guard self.generation == token, self.currentTrack?.id == track.id, self.isPlaying else { return }
                    self.startLocal(track, at: self.progress, token: token, isMigration: true, fileURL: streamURL)
                    return
                }
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

    /// Download a stream into `InternalAudioCache` so Automix/Duet can stem-bake.
    /// Returns nil when the track cannot be materialized (caller falls back to live path).
    private func materializeLocalAudio(for track: Track) async throws -> URL? {
        if let cached = findLocalOrCachedAudioFile(for: track, respectingQuality: false) {
            return cached
        }
        if !track.isStream, track.url.isFileURL {
            return FileManager.default.fileExists(atPath: track.url.path) ? track.url : nil
        }

        let streamURL: URL?
        if let active = activeStreamURL, currentTrack?.id == track.id {
            streamURL = active
        } else if let str = track.streamUrlString, let u = URL(string: str),
                  u.scheme == "http" || u.scheme == "https" {
            streamURL = u
        } else if track.url.scheme == "http" || track.url.scheme == "https" {
            streamURL = track.url
        } else {
            let ymID = Self.yandexTrackID(from: track)
            guard !ymID.isEmpty else { return nil }
            let info = try await YandexMusicService.shared.getStreamInfo(
                for: ymID,
                preferredQuality: audioQuality,
                preferredBitrate: audioQuality.targetBitrate
            )
            streamURL = info.url
            if currentTrack?.id == track.id {
                currentTrack?.streamUrlString = info.url.absoluteString
            }
        }
        guard let remote = streamURL else { return nil }
        if remote.isFileURL {
            return FileManager.default.fileExists(atPath: remote.path) ? remote : nil
        }

        let ext = remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension
        let (temporaryURL, response) = try await URLSession.shared.download(from: remote)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            discardTemporaryDownload(temporaryURL)
            return nil
        }
        // Validate before committing to the playback cache.
        let validated = try AVAudioFile(forReading: temporaryURL)
        guard validated.length > 0 else {
            discardTemporaryDownload(temporaryURL)
            return nil
        }
        return try InternalAudioCache.store(temporaryURL: temporaryURL, for: track.id, fileExtension: ext)
    }

    private func discardTemporaryDownload(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Keep enough runway after LAND so B cannot instantly finish and freeze.
    private func safeAutomixHandoffPosition(for track: Track, proposed: Double) -> Double {
        let dur = track.duration
        let cue = mashupIncomingCueSec > 0 ? mashupIncomingCueSec : incomingStartPosition
        let raw = proposed.isFinite ? max(0, proposed) : max(0, cue)
        guard dur.isFinite, dur > 2 else { return raw }
        let runway = min(12, max(6, dur * 0.08))
        let maxPos = max(0, dur - runway)
        if raw <= maxPos { return raw }
        // Proposed overshoots (short track / late bake lag) — fall back to musical cue, then head.
        let cueClamped = min(max(0, cue), maxPos)
        return cueClamped
    }

    /// If LAND left a silent/frozen deck, restart B once after a short settle.
    private func verifyAutomixHandoffPlayback(expected: Track, at seconds: Double) {
        let token = generation
        let trackID = expected.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let before = self.playbackProgress
            try? await Task.sleep(for: .milliseconds(450))
            guard self.generation == token, self.currentTrack?.id == trackID else { return }
            let after = self.playbackProgress
            let streamDead = self.isUsingStreamPlayer && (
                self.activeStreamingPlayer.currentItem == nil
                    || self.activeStreamingPlayer.rate == 0
                    || self.activeStreamingPlayer.error != nil
                    || self.activeStreamingPlayer.timeControlStatus == .paused
            )
            // Rate can look live while currentTime never leaves the handoff cue.
            let streamFrozen = self.isUsingStreamPlayer
                && abs(after - before) < 0.08
                && abs(after - seconds) < 1.5
            let nativeDead = !self.isUsingStreamPlayer && (
                self.activeAudioFile == nil || !self.activePlayer.isPlaying
            )
            let markedStopped = !self.isPlaying
            guard streamDead || streamFrozen || nativeDead || markedStopped else { return }
            AutoMixSessionLog.shared.fault(
                String(
                    format: "land.recover streamDead=%d frozen=%d nativeDead=%d stopped=%d pos=%.1f",
                    streamDead ? 1 : 0,
                    streamFrozen ? 1 : 0,
                    nativeDead ? 1 : 0,
                    markedStopped ? 1 : 0,
                    after
                )
            )
            SonivoDiagnostics.log(
                "[AutoMix] LAND recovery restart for \(expected.title)",
                tag: "AUTOMIX"
            )
            self.suppressTrackFinishUntil = Date().addingTimeInterval(2.0)
            self.isPlaying = true
            self.start(at: seconds)
        }
    }

    /// Open a local cache without fighting the live AVPlayer / AVAudioEngine handle.
    /// Keeps any private copy in the mashup temp list so LAND can still glide.
    private func openAutomixPlaybackFile(_ url: URL) throws -> AVAudioFile {
        let opened = try MidSideStemBaker.openPlaybackSource(url)
        if let scratch = opened.scratch {
            mashupBakeTempURLs.append(scratch)
        }
        guard opened.file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return opened.file
    }

    /// Synchronous local handoff used at Automix LAND — sets anchors immediately so
    /// the UI never freezes waiting on an async `startLocal` Task.
    private func handoffLocalPlayback(track: Track, fileURL: URL, at seconds: Double) throws {
        let audioFile = try openAutomixPlaybackFile(fileURL)

        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        isUsingStreamPlayer = false
        streamingPlayerA.pause()
        streamingPlayerB.pause()
        streamingPlayerA.replaceCurrentItem(with: nil)
        streamingPlayerB.replaceCurrentItem(with: nil)
        activeStreamingPlayer.pause()
        idleStreamingPlayer.pause()

        localSegmentTokens.removeAll()
        lyricsLocalSegments.removeAll()
        playerA.stop()
        playerB.stop()
        stopBeatLoop()
        activePlayer = playerA
        playerA.volume = 1
        playerB.volume = 0
        timePitchA.rate = 1
        timePitchA.pitch = 0
        timePitchA.bypass = true
        timePitchB.rate = 1
        timePitchB.pitch = 0
        timePitchB.bypass = true

        if !engine.isRunning { try engine.start() }

        let pos = PlaybackResumePolicy.position(seconds, duration: track.duration)
        activeLocalURL = fileURL
        activeAudioFile = audioFile
        incomingAudioFile = nil
        let facts = LocalAudioQualityReader.read(audioFile)
        currentCodec = facts.codec
        currentBitrate = facts.bitrate
        scheduleLocalSegment(audioFile, on: playerA, at: pos)
        playerA.play()
        isPlaying = true
        anchorDate = Date()
        anchorOffset = pos
        pausedProgress = pos
        progress = pos
        streamDuration = track.duration
        startTimer()
        applyEQ()
    }

    /// Automix LAND: mount dry B on the outgoing node while B stem keeps playing,
    /// then cut the stem — avoids the silence gap of stop-both-then-open-file.
    private func landAutomixOntoDryB(track: Track, fileURL: URL, at seconds: Double, glide: Double) throws {
        let audioFile = try openAutomixPlaybackFile(fileURL)

        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        isUsingStreamPlayer = false
        mashupBakeRealIncomingURL = nil
        mashupPlayingMasterBake = false

        let pos = PlaybackResumePolicy.position(seconds, duration: track.duration)
        let dryNode = activePlayer
        let stemNode = idlePlayer

        localSegmentTokens.removeValue(forKey: ObjectIdentifier(dryNode))
        // Keep stemNode token until after dry is audible.
        dryNode.stop()
        dryNode.volume = 0
        if !engine.isRunning { try engine.start() }

        activeLocalURL = fileURL
        activeAudioFile = audioFile
        incomingAudioFile = nil
        let facts = LocalAudioQualityReader.read(audioFile)
        currentCodec = facts.codec
        currentBitrate = facts.bitrate
        scheduleLocalSegment(audioFile, on: dryNode, at: pos)
        dryNode.play()
        dryNode.volume = 0
        // Keep the stem the listener is already hearing and ease the dry file in.
        // An instant cut was the jump at the end of AutoMix.
        stemNode.volume = 1
        startLandGlide(stem: stemNode, dry: dryNode, overlap: glide)

        activePlayer = dryNode == playerA ? playerA : playerB
        // Ensure the other deck is silent.
        if activePlayer === playerA {
            playerB.volume = 0
        } else {
            playerA.volume = 0
        }
        timePitchA.rate = 1
        timePitchA.pitch = 0
        timePitchA.bypass = true
        timePitchB.rate = 1
        timePitchB.pitch = 0
        timePitchB.bypass = true

        isPlaying = true
        anchorDate = Date()
        anchorOffset = pos
        pausedProgress = pos
        progress = pos
        streamDuration = track.duration
        startTimer()
        applyEQ()
    }

    /// File position of a scheduled segment, including the frame it started from.
    private func renderedFileSeconds(node: AVAudioPlayerNode, file: AVAudioFile?) -> Double? {
        guard let file else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0 else { return nil }
        let scheduled = lyricsLocalSegments[ObjectIdentifier(node)]?.start ?? 0
        return scheduled + Double(playerTime.sampleTime) / rate
    }

    /// Short equal-power overlap so the dry song replaces the baked vocal in place.
    private func startLandGlide(stem: AVAudioPlayerNode, dry: AVAudioPlayerNode, overlap requested: Double) {
        landOverlapTimer?.invalidate()
        let token = UUID()
        landOverlapToken = token
        let overlap = min(0.9, max(0.35, requested))
        let started = Date()
        // Player nodes are not Sendable. Remember which deck is the bake and
        // touch both only on the main actor, or Swift 6 rejects the timer hop.
        guard dry !== stem else { return }
        let stemIsA = stem === playerA
        let timer = Timer(timeInterval: overlap / 16.0, repeats: true) { [weak self] timer in
            let elapsed = -started.timeIntervalSinceNow
            let u = min(1, max(0, elapsed / overlap))
            let ease = u * u * (3 - 2 * u)
            let stemGain = Float(cos(ease * Double.pi * 0.5))
            let dryGain = Float(sin(ease * Double.pi * 0.5))
            let done = u >= 1
            if done { timer.invalidate() }
            Task { @MainActor [weak self] in
                guard let self, self.landOverlapToken == token else { return }
                let baked = stemIsA ? self.playerA : self.playerB
                let song = stemIsA ? self.playerB : self.playerA
                baked.volume = done ? 0 : stemGain
                song.volume = done ? 1 : dryGain
                guard done else { return }
                self.landOverlapTimer = nil
                baked.stop()
                self.clearMashupBakeTemps()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landOverlapTimer = timer
    }

    /// Beatmatched mashup modes (AutoMix ONE VOCAL + Modern Duet).
    private var isMashupTransitionMode: Bool {
        transitionMode == .automix || transitionMode == .duet
    }

    /// Park until the musical cue. Pause does not cancel the mix; the playhead
    /// just sits, and we continue when playback resumes.
    ///
    /// Field 1077: a `Task.detached` sleep loop parked inside the prep Task never
    /// resumed to bake.pending while TICK still advanced past the cue — use a
    /// RunLoop timer (same path as session TICK) plus playhead-driven
    /// `firePendingMashupLiveArmIfNeeded` so the mix starts at the cue.
    private func waitUntilMashupCue(_ cue: Double) async -> Bool {
        let safeCue = cue.isFinite ? max(0, cue) : 0
        let posAtStart = playbackProgress
        let durAtStart = max(playbackDuration, duration)
        if isTransitioning {
            if posAtStart + 0.25 >= safeCue { return true }
            if durAtStart > 1, posAtStart >= durAtStart - 0.35 { return true }
            if durAtStart > 1, safeCue >= durAtStart - 0.75 { return true }
            if incomingLaneReady { return true }
        } else {
            return false
        }

        let waitStarted = Date()
        let deadline = waitStarted.addingTimeInterval(max(0.05, safeCue - posAtStart - 0.2))
        let box = MashupCueWaitBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                box.setContinuation(continuation)
                // 20 Hz — same RunLoop.common as Automix session TICK / transition fader.
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self else {
                        box.finish(false)
                        return
                    }
                    Task { @MainActor in
                        // Prep cancel clears isTransitioning — do not trust
                        // Task.isCancelled on this nested Timer Task.
                        if !self.isTransitioning {
                            box.finish(false)
                            return
                        }
                        if self.incomingLaneReady {
                            box.finish(true)
                            return
                        }
                        let now = Date()
                        let pos = self.playbackProgress
                        let dur = max(self.playbackDuration, self.duration)
                        if self.isPlaying || pos + 0.05 >= posAtStart {
                            if pos + 0.25 >= safeCue {
                                box.finish(true)
                                return
                            }
                            if dur > 1, pos >= dur - 0.35 {
                                box.finish(true)
                                return
                            }
                            // Cue past the tail — start the mix now rather than wait for EOF.
                            if dur > 1, safeCue >= dur - 0.75 {
                                box.finish(true)
                                return
                            }
                        }
                        if self.isPlaying {
                            let estimated = posAtStart + now.timeIntervalSince(waitStarted)
                            if estimated + 0.25 >= safeCue {
                                box.finish(true)
                                return
                            }
                            if dur > 1, estimated >= dur - 0.35 {
                                box.finish(true)
                                return
                            }
                            if now >= deadline {
                                box.finish(true)
                                return
                            }
                        }
                    }
                }
                box.setTimer(timer)
                RunLoop.main.add(timer, forMode: .common)
            }
        } onCancel: {
            box.finish(false)
        }
    }

    /// Start live Automix the instant the playhead crosses the musical cue —
    /// independent of whether the prep Task's wait/bakeProbe woke up (field 1077).
    private func firePendingMashupLiveArmIfNeeded() {
        guard let arm = pendingMashupLiveArm, !arm.fired else { return }
        guard isTransitioning, !incomingLaneReady else { return }
        guard transitionRequestID == arm.transitionID, generation == arm.generation else {
            pendingMashupLiveArm = nil
            return
        }
        guard isPlaying, currentTrack?.id == arm.currentTrackID else { return }

        let pos = playbackProgress
        let dur = max(playbackDuration, duration)
        let atCue = pos + 0.15 >= arm.cueA
            || (dur > 1 && pos >= dur - 0.35)
            || (dur > 1 && arm.cueA >= dur - 0.75)
        guard atCue else { return }

        arm.fired = true
        beginLiveAutomixAtCue(arm: arm)
    }

    /// Audible Automix fader at the cue while bake may still be cooking.
    private func beginLiveAutomixAtCue(arm: PendingMashupLiveArm) {
        guard isTransitioning, !incomingLaneReady else { return }
        guard transitionRequestID == arm.transitionID, generation == arm.generation else { return }

        mashupBakeFailedUseCrossfade = true
        AutoMixSessionLog.shared.event("bake.pending → live Automix at cue")

        var liveArmed = arm.prearmed
        if !liveArmed {
            let prepared = incomingAudioFile ?? prepareMashupIncomingFile(arm.inURL)
            if let prepared {
                do {
                    try armPreparedMashupIncoming(
                        file: prepared,
                        on: idlePlayer,
                        at: arm.cueB
                    )
                    liveArmed = true
                    arm.prearmed = true
                } catch {
                    AutoMixSessionLog.shared.fault(
                        "lane.arm \(error.localizedDescription)"
                    )
                }
            }
        }
        guard liveArmed else {
            AutoMixSessionLog.shared.fault("lane.arm missing at cue → keep waiting")
            arm.fired = false
            return
        }

        let transitionID = arm.transitionID
        let cueA = arm.cueA
        let cueB = arm.cueB
        let blend = arm.blend
        let handoff = arm.handoff
        let inURL = arm.inURL
        let bakeTask = arm.bakeTask

        incomingLaneReady = true
        transitionStartTime = Date()
        if isMashupTransitionMode {
            if isUsingStreamPlayer, let item = activeStreamingPlayer.currentItem {
                StreamBeatTap.shared.attach(to: item)
            }
            let rates = activeMashupStyle.playbackRates(progress: 0)
            if isUsingStreamPlayer {
                activeStreamingPlayer.rate = rates.outgoing
            } else {
                applyMashupTimePitch(progress: 0, outgoing: true, rate: rates.outgoing)
            }
            applyMashupTimePitch(progress: 0, outgoing: false, rate: rates.incoming)
            applyMashupTransitionEQ(progress: 0)
            AutoMixDJEngine.shared.markMashupProgress(0)
            AutoMixDJEngine.shared.currentBPM = Double(activeMashupStyle.targetBPM)
            AutoMixDJEngine.shared.statusBadge = activeMashupStyle.phaseLabel(progress: 0)
        }
        startTransitionTimer()

        // Late stem upgrade — same contract as the former bake.pending block.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let late = await bakeTask.result
            guard self.transitionRequestID == transitionID, self.isTransitioning else {
                if case .success(let pair) = late {
                    MidSideStemBaker.removeTempFiles([pair.outgoing, pair.incoming])
                }
                return
            }
            guard case .success(let stemPair) = late else { return }
            let live = self.playbackProgress
            let heard = max(0, live - cueA)
            let landAt = blend * handoff
            if heard >= landAt - 1.5 {
                MidSideStemBaker.removeTempFiles([stemPair.outgoing, stemPair.incoming])
                AutoMixSessionLog.shared.event(
                    String(format: "bake.late-drop lag=%.2fs", heard)
                )
                return
            }
            do {
                self.mashupBakeFailedUseCrossfade = false
                self.clearMashupBakeTemps()
                self.mashupBakeTempURLs = [stemPair.outgoing, stemPair.incoming]
                self.mashupBakeRealIncomingURL = inURL
                self.mashupBakeIncomingBaseCue = cueB
                self.mashupBakeOutgoingBaseCue = cueA
                self.mashupIncomingCueSec = cueB
                self.incomingStartPosition = cueB
                let wasStream = self.isUsingStreamPlayer
                try self.playMashupStemPair(
                    outgoingURL: stemPair.outgoing,
                    incomingURL: stemPair.incoming,
                    startOffsetSec: heard
                )
                if wasStream {
                    self.mashupStemEntryStartedAt = Date()
                    self.mashupStemEntryDuration = 0.35
                    self.mashupStemEntryFromStream = true
                }
                let enterP = min(1, heard / max(0.001, blend))
                let rates = self.activeMashupStyle.playbackRates(progress: enterP)
                self.applyMashupTimePitch(progress: enterP, outgoing: true, rate: rates.outgoing)
                self.applyMashupTimePitch(progress: enterP, outgoing: false, rate: rates.incoming)
                self.applyMashupTransitionEQ(progress: enterP)
                let mixClock = Date()
                self.transitionStartTime = mixClock.addingTimeInterval(-heard)
                self.anchorDate = mixClock
                let heardA = cueA + heard
                self.anchorOffset = heardA
                self.pausedProgress = heardA
                self.progress = heardA
                self.startTimer()
                AutoMixSessionLog.shared.event(
                    String(format: "bake.upgrade lag=%.2fs", heard)
                )
            } catch {
                MidSideStemBaker.removeTempFiles([stemPair.outgoing, stemPair.incoming])
                self.mashupBakeFailedUseCrossfade = true
            }
        }
    }

    /// Pre-open B during bake lead-in so cue-time arm is instant (no decode stall).
    private func prepareMashupIncomingFile(_ url: URL) -> AVAudioFile? {
        do {
            let file = try openAutomixPlaybackFile(url)
            incomingAudioFile = file
            incomingIsStream = false
            return file
        } catch {
            AutoMixSessionLog.shared.fault(
                "lane.prepare \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Silent local B on the idle node — ready for live Automix without bake.
    private func armPreparedMashupIncoming(
        file: AVAudioFile,
        on node: AVAudioPlayerNode,
        at startAt: Double
    ) throws {
        incomingIsStream = false
        incomingAudioFile = file
        incomingQuality = LocalAudioQualityReader.read(file)
        scheduleLocalSegment(file, on: node, at: startAt)
        node.volume = 0
        if !engine.isRunning { try engine.start() }
        node.play()
    }

    /// One failure must not cancel-and-reschedule the same pair. Keep A playing,
    /// and if the song is already over (or silent), start the next one a single time.
    private func giveUpMashupAndKeepPlaying(_ error: Error) {
        if !isMashupTransitionMode {
            cancelTransition()
            return
        }
        AutoMixSessionLog.shared.fault("transition.fail \(error.localizedDescription)")
        SonivoDiagnostics.log(
            "[Mashup] transition failed, not retrying: \(error.localizedDescription)",
            tag: "AUDIO"
        )
        if let id = currentTrack?.id {
            mashupGiveUpTrackID = id
        }
        let pos = isUsingStreamPlayer ? progress : liveProgress()
        let nativeSilent = !isUsingStreamPlayer && !activePlayer.isPlaying
        let streamSilent = isUsingStreamPlayer && (
            activeStreamingPlayer.currentItem == nil
                || activeStreamingPlayer.rate < 0.05
                || activeStreamingPlayer.timeControlStatus == .paused
        )
        let nearEnd = duration <= 1 || pos >= duration - 1.2 || nativeSilent || streamSilent
        let next = nearEnd ? (incomingTrack ?? peekNext(auto: true)) : nil
        cancelTransition()
        if let next {
            currentTrack = next
            isPlaying = true
            start(at: 0)
            return
        }
        // Mid-song failure: cancel silenced the idle deck — keep A audible.
        guard isPlaying else { return }
        if isUsingStreamPlayer {
            activeStreamingPlayer.volume = volume
            activeStreamingPlayer.playImmediately(atRate: 1.0)
        } else {
            activePlayer.volume = 1
            if !activePlayer.isPlaying { activePlayer.play() }
        }
    }

    private func scheduleTransitionIfNeeded() {
        guard transitionMode == .crossfade || isMashupTransitionMode,
              !isTransitioning, !transitionScheduled, isPlaying, let current = currentTrack else { return }

        let currentPos = isUsingStreamPlayer ? progress : liveProgress()
        let totalDur = duration
        guard totalDur > 5, let nextTrack = peekNext(auto: true) else { return }

        if isMashupTransitionMode {
            if mashupGiveUpTrackID == current.id { return }
            let blend = resolveMashupBlend(outgoing: current, incoming: nextTrack, duration: totalDur)
            let leadIn = max(0, blend.outgoingCueSec - Self.automixBakeLeadSec)
            guard currentPos >= leadIn else { return }
            var style = resolveMashupStyle(outgoing: current, incoming: nextTrack, duration: totalDur)
            if transitionMode == .automix {
                style.moodLand = blend.landProgress
                style.handoffAt = blend.landProgress
            }
            scheduleSimpleTransition(
                current: current,
                nextTrack: nextTrack,
                blendDuration: blend.blendDurationSec,
                incomingStart: blend.incomingStartSec,
                mashupBadge: "\(style.archetypeName) · \(blend.reason)",
                mashupStyle: style,
                outgoingCue: blend.outgoingCueSec
            )
        } else {
            let blendDuration = max(1, crossfadeDuration)
            let cue = max(0, totalDur - blendDuration)
            guard currentPos >= cue else { return }
            scheduleSimpleTransition(
                current: current,
                nextTrack: nextTrack,
                blendDuration: blendDuration,
                incomingStart: 0,
                mashupBadge: nil,
                mashupStyle: nil,
                outgoingCue: nil
            )
        }
    }

    private func resolveMashupStyle(outgoing: Track, incoming: Track, duration totalDur: Double) -> MashupLiveStyle {
        let analysis = AutoMixV2AnalysisRuntime.shared
        let outProfile = analysis.currentProfile.flatMap { mashupProfileMatches($0, track: outgoing) ? $0 : nil }
        let inProfile = analysis.nextProfile.flatMap { mashupProfileMatches($0, track: incoming) ? $0 : nil }
        let plan = (outProfile != nil && inProfile != nil) ? analysis.transitionPlan : nil
        let incomingDur = incoming.duration > 0 ? incoming.duration : totalDur
        var style = MashupLiveStyle.resolve(
            plan: plan,
            outgoing: outProfile,
            incoming: inProfile,
            outgoingDuration: totalDur,
            incomingDuration: incomingDur
        )
        // User selected Duet → keep dual-vocal grammar (never slide into ONE VOCAL Automix).
        if transitionMode == .duet {
            style.applyDuetPlaybackCharacter()
        } else if transitionMode == .automix {
            // Live/stream Automix without stems must ONE-VOCAL carve — two dry mixes = mud.
            style.applyAutomixPlaybackCharacter()
        }
        return style
    }

    /// Prefer MixPlanner + neural/lyric mixOut/mixIn (Apple word/phrase land),
    /// then profile downbeat grid. MoodAutomix only shapes blend length / LAND —
    /// it must not replace a musical cue with a raw energy entry.
    /// Blend length auto-adjusts from detection — the crossfade slider is unused here.
    private func resolveMashupBlend(outgoing: Track, incoming: Track, duration totalDur: Double) -> LiveMashupBlend {
        let preferred = MashupBlendScheduler.defaultPreferredBlendSec
        let analysis = AutoMixV2AnalysisRuntime.shared
        let outProfile = analysis.currentProfile.flatMap { mashupProfileMatches($0, track: outgoing) ? $0 : nil }
        let inProfile = analysis.nextProfile.flatMap { mashupProfileMatches($0, track: incoming) ? $0 : nil }
        let incomingDur = incoming.duration > 0 ? incoming.duration : totalDur

        if outProfile != nil, inProfile != nil,
           let plan = analysis.transitionPlan,
           plan.type != .none,
           MashupTransitionExecutor.durationSeconds(for: plan) >= MashupBlendScheduler.minimumBlendSec {
            var blend = clampMashupBlendDuration(MashupTransitionExecutor.durationSeconds(for: plan))
            var cue = MashupBlendScheduler.reanchorOutgoingCue(
                preferredCue: plan.aOutStartSec,
                totalDur: totalDur,
                blend: blend
            )
            let inCue = MashupBlendScheduler.clampAutomixIncomingCue(
                preferred: max(0, plan.bInStartSec),
                incomingDur: incomingDur
            )
            var land = 0.86
            var reason = plan.reason
            if transitionMode == .automix {
                let mood = MoodAutomix.window(
                    outgoingDuration: totalDur,
                    incomingDuration: incomingDur,
                    outgoing: outProfile,
                    incoming: inProfile
                )
                land = mood.landProgress
                if mood.mood == "tight" {
                    blend = clampMashupBlendDuration(min(blend, mood.blendSec))
                    cue = MashupBlendScheduler.reanchorOutgoingCue(
                        preferredCue: plan.aOutStartSec,
                        totalDur: totalDur,
                        blend: blend
                    )
                } else if mood.mood == "wash" {
                    blend = clampMashupBlendDuration(max(blend, mood.blendSec))
                    cue = MashupBlendScheduler.reanchorOutgoingCue(
                        preferredCue: min(plan.aOutStartSec, max(0, totalDur - blend)),
                        totalDur: totalDur,
                        blend: blend
                    )
                }
                reason = "\(plan.reason) · \(mood.mood)"
            }
            return LiveMashupBlend(
                outgoingCueSec: cue,
                blendDurationSec: blend,
                incomingStartSec: inCue,
                reason: reason,
                landProgress: land
            )
        }

        if outProfile != nil || inProfile != nil {
            let scheduled = MashupBlendScheduler.schedule(
                outgoingDuration: totalDur,
                incomingDuration: incomingDur,
                preferredBlendSec: preferred,
                outgoing: outProfile,
                incoming: inProfile
            )
            if transitionMode == .automix {
                let mood = MoodAutomix.window(
                    outgoingDuration: totalDur,
                    incomingDuration: incomingDur,
                    outgoing: outProfile,
                    incoming: inProfile
                )
                var blend = scheduled.blendDurationSec
                var cue = scheduled.outgoingCueSec
                if mood.mood == "tight" {
                    blend = clampMashupBlendDuration(min(blend, mood.blendSec))
                    cue = MashupBlendScheduler.reanchorOutgoingCue(
                        preferredCue: outProfile?.mixOutSec ?? cue,
                        totalDur: totalDur,
                        blend: blend
                    )
                } else if mood.mood == "wash" {
                    blend = clampMashupBlendDuration(max(blend, mood.blendSec))
                    cue = MashupBlendScheduler.reanchorOutgoingCue(
                        preferredCue: outProfile?.mixOutSec ?? cue,
                        totalDur: totalDur,
                        blend: blend
                    )
                }
                let inCue = MashupBlendScheduler.clampAutomixIncomingCue(
                    preferred: scheduled.incomingStartSec,
                    incomingDur: incomingDur
                )
                return LiveMashupBlend(
                    outgoingCueSec: cue,
                    blendDurationSec: blend,
                    incomingStartSec: inCue,
                    reason: "\(scheduled.reason) · \(mood.mood)",
                    landProgress: mood.landProgress
                )
            }
            return scheduled
        }

        if transitionMode == .automix {
            let placed = MoodAutomix.placed(
                outgoingDuration: totalDur,
                incomingDuration: incomingDur,
                outgoing: outProfile,
                incoming: inProfile
            )
            return LiveMashupBlend(
                outgoingCueSec: placed.outgoingCueSec,
                blendDurationSec: placed.blendSec,
                incomingStartSec: placed.incomingStartSec,
                reason: placed.reason,
                landProgress: placed.landProgress
            )
        }
        return MashupBlendScheduler.schedule(
            outgoingDuration: totalDur,
            incomingDuration: incomingDur,
            preferredBlendSec: preferred,
            outgoing: outProfile,
            incoming: inProfile
        )
    }

    /// Materialize + separate this long before the musical cue. Baking at the
    /// cue spent the whole outro on HTDemucs, then the slice ended and the
    /// next song hard-cut a few seconds in.
    private static let automixBakeLeadSec: Double = 22

    /// Read the outro and the intro, then refine blend length / LAND from mood.
    /// Never replace MixPlanner / neural lyric mixOut·mixIn with a raw energy entry —
    /// that is what made Automix miss Apple-style word land and BPM handoff.
    private func retargetAutomixFromEnergy(
        outgoingURL: URL,
        incomingURL: URL,
        playerDuration: Double
    ) async -> (cueA: Double, cueB: Double, blend: Double)? {
        let bins = await Task.detached(priority: .userInitiated) {
            MoodEnergyProbe.bins(outgoingURL: outgoingURL, incomingURL: incomingURL)
        }.value
        guard let bins else {
            AutoMixSessionLog.shared.event("mood.scan miss")
            return nil
        }
        let live = isUsingStreamPlayer ? progress : liveProgress()
        let totalDur = playerDuration > 1 ? playerDuration : bins.outgoingDuration
        let incomingDur = bins.incomingDuration > 1
            ? bins.incomingDuration
            : (incomingTrack?.duration ?? bins.incomingDuration)
        let placed = MoodAutomix.placed(
            outgoingDuration: totalDur,
            incomingDuration: incomingDur,
            outgoingTail: bins.outgoingTail,
            incomingHead: bins.incomingHead,
            notBefore: max(0, live - 0.2)
        )
        let analysis = AutoMixV2AnalysisRuntime.shared
        var blend = placed.blendSec
        var cueA = placed.outgoingCueSec
        var cueB = placed.incomingStartSec
        var source = placed.mood

        if let plan = analysis.transitionPlan,
           plan.type != .none,
           let outTrack = currentTrack,
           let inTrack = incomingTrack,
           let outP = analysis.currentProfile, mashupProfileMatches(outP, track: outTrack),
           let inP = analysis.nextProfile, mashupProfileMatches(inP, track: inTrack) {
            if placed.mood == "tight" {
                blend = clampMashupBlendDuration(min(blend, placed.blendSec))
            } else if placed.mood == "wash" {
                blend = clampMashupBlendDuration(max(blend, placed.blendSec))
            }
            cueA = MashupBlendScheduler.reanchorOutgoingCue(
                preferredCue: plan.aOutStartSec,
                totalDur: totalDur,
                blend: blend
            )
            cueB = MashupBlendScheduler.clampAutomixIncomingCue(
                preferred: max(0, plan.bInStartSec),
                incomingDur: incomingDur
            )
            source = "\(placed.mood)+plan"
        } else if let outTrack = currentTrack,
                  let outP = analysis.currentProfile,
                  mashupProfileMatches(outP, track: outTrack),
                  outP.mixOutSec > 1 {
            if placed.mood == "tight" {
                blend = clampMashupBlendDuration(min(blend, placed.blendSec))
            } else if placed.mood == "wash" {
                blend = clampMashupBlendDuration(max(blend, placed.blendSec))
            }
            cueA = MashupBlendScheduler.reanchorOutgoingCue(
                preferredCue: outP.mixOutSec,
                totalDur: totalDur,
                blend: blend
            )
            if let inTrack = incomingTrack,
               let inP = analysis.nextProfile,
               mashupProfileMatches(inP, track: inTrack) {
                cueB = MashupBlendScheduler.clampAutomixIncomingCue(
                    preferred: inP.mixInSec,
                    incomingDur: incomingDur
                )
            }
            source = "\(placed.mood)+mixOut"
        }

        let room = max(MashupBlendScheduler.minimumBlendSec, totalDur - cueA)
        blend = clampMashupBlendDuration(min(blend, room))
        if cueA < live - 0.2 {
            cueA = min(max(live - 0.2, totalDur * MashupBlendScheduler.minimumPlayedFraction), max(0, totalDur - MashupBlendScheduler.minimumBlendSec))
            blend = clampMashupBlendDuration(min(blend, max(MashupBlendScheduler.minimumBlendSec, totalDur - cueA)))
        }

        transitionDuration = blend
        incomingStartPosition = cueB
        mashupIncomingCueSec = cueB
        activeMashupStyle.moodLand = placed.landProgress
        activeMashupStyle.handoffAt = placed.landProgress
        AutoMixSessionLog.shared.event(
            String(
                format: "mood.pick %@ blend=%.1f inCue=%.1f land=%.2f cueA=%.1f",
                source,
                blend,
                cueB,
                placed.landProgress,
                cueA
            )
        )
        return (cueA, cueB, blend)
    }

    private func mashupProfileMatches(_ profile: TrackProfile, track: Track) -> Bool {
        if track.isStream {
            guard let raw = YandexMusicService.ymId(fromFileName: track.fileName) else { return false }
            return profile.trackID.raw == raw
        }
        return profile.trackID.raw == track.id.uuidString
    }

    private func clampMashupBlendDuration(_ value: Double) -> Double {
        min(MashupBlendScheduler.maximumBlendSec,
            max(MashupBlendScheduler.minimumBlendSec, value))
    }

    private func scheduleSimpleTransition(
        current: Track,
        nextTrack: Track,
        blendDuration: Double,
        incomingStart: Double,
        mashupBadge: String?,
        mashupStyle: MashupLiveStyle?,
        outgoingCue: Double?
    ) {
        // Drop any leftover prep / MIXING timer from a prior land (field zombie badge).
        transitionPreparationTask?.cancel()
        transitionPreparationTask = nil
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil
        incomingLaneReady = false
        pendingMashupLiveArm = nil

        transitionScheduled = true
        isTransitioning = true
        mashupBakeFailedUseCrossfade = false
        incomingIsStream = nextTrack.isStream
        transitionDuration = blendDuration
        incomingTrack = nextTrack
        let styleForLog = mashupStyle ?? activeMashupStyle
        AutoMixSessionLog.shared.event(
            String(
                format: "transition.schedule mode=%@ blend=%.1fs inCue=%.1f A=%@ → B=%@ badge=%@ fp=%@",
                transitionMode.rawValue,
                blendDuration,
                incomingStart,
                current.title,
                nextTrack.title,
                mashupBadge ?? "-",
                mashupStyle?.transitionFingerprint ?? styleForLog.transitionFingerprint
            )
        )
        let liveAtSchedule = isUsingStreamPlayer ? progress : liveProgress()
        if let outgoingCue, isMashupTransitionMode, liveAtSchedule + 0.5 < outgoingCue {
            AutoMixSessionLog.shared.event(
                String(format: "bake.lead cue=%.1f pos=%.1f", outgoingCue, liveAtSchedule)
            )
        }
        incomingQuality = nil
        metadataSwapped = false
        metadataTrack = nil
        incomingStartPosition = max(0, incomingStart)
        mashupIncomingCueSec = max(0, incomingStart)
        activeMashupStyle = mashupStyle ?? .fallback
        let analysisPlan = AutoMixV2AnalysisRuntime.shared.transitionPlan
        activeTransitionPlan = (mashupStyle != nil) ? analysisPlan : nil
        mashupPhraseLoopCueSec = isUsingStreamPlayer ? progress : liveProgress()
        if let plan = activeTransitionPlan, plan.loopBarsA > 0 {
            liveLoopNextBar = Double(plan.loopBarsA)
        } else {
            liveLoopNextBar = .infinity
        }
        let mashup = isMashupTransitionMode
        let strategyName = activeMashupStyle.isDuet ? "DUET" : "MASHUP"
        AutoMixDJEngine.shared.isTransitionActive = transitionMode == .crossfade || mashup
        AutoMixDJEngine.shared.activeStrategyName = mashup ? strategyName : (transitionMode == .crossfade ? "CROSSFADE" : "GAPLESS")
        AutoMixDJEngine.shared.transitionProgress = 0
        // Mixing badge only when the blend is actually audible (lane ready) — not while baking.
        AutoMixDJEngine.shared.statusBadge = nil
        AutoMixDJEngine.shared.currentBPM = mashup ? Double(activeMashupStyle.targetBPM) : 0
        // Lock outgoing tempo immediately so B can meet A on the grid.
        if mashup {
            let rates = activeMashupStyle.playbackRates(progress: 0)
            if isUsingStreamPlayer {
                activeStreamingPlayer.rate = rates.outgoing
            } else {
                applyMashupTimePitch(progress: 0, outgoing: true, rate: rates.outgoing)
            }
        }
        if mashup, let mashupBadge, !mashupBadge.isEmpty {
            SonivoDiagnostics.log("[Mashup] \(activeMashupStyle.reason) · \(mashupBadge)", tag: "AUDIO")
        }

        let transitionID = UUID()
        transitionRequestID = transitionID
        let token = generation
        let nextURL = findLocalOrCachedAudioFile(for: nextTrack)
        incomingIsStream = nextURL == nil && (nextTrack.isStream || nextTrack.streamUrlString != nil)
        let targetStream = idleStreamingPlayer
        let targetNode = idlePlayer
        let startAt = incomingStartPosition
        let outgoingCacheURL = findLocalOrCachedAudioFile(for: current)
        let cueAForBake = isUsingStreamPlayer ? progress : liveProgress()
        let musicalOutgoingCue = outgoingCue
        transitionPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Mashup/Duet need real local PCM for stem bake. Yandex streams often
                // have no cache yet — materialize both sides or the mix is just a badge.
                var outURLForBake = outgoingCacheURL
                var inURLForBake = nextURL ?? self.findLocalOrCachedAudioFile(for: nextTrack)
                if mashup {
                    if outURLForBake == nil {
                        outURLForBake = try? await self.materializeLocalAudio(for: current)
                    }
                    if inURLForBake == nil {
                        inURLForBake = try? await self.materializeLocalAudio(for: nextTrack)
                    }
                    if outURLForBake == nil || inURLForBake == nil {
                        SonivoDiagnostics.log(
                            "[Mashup] stem bake skipped — missing local A/B (out:\(outURLForBake != nil) in:\(inURLForBake != nil))",
                            tag: "AUDIO"
                        )
                        AutoMixSessionLog.shared.event(
                            "bake.skip missingLocal out=\(outURLForBake != nil) in=\(inURLForBake != nil)"
                        )
                    } else {
                        AutoMixSessionLog.shared.event("bake.start blend=\(String(format: "%.1f", self.transitionDuration))s")
                    }
                }
                let shouldBakeStems = mashup && outURLForBake != nil && inURLForBake != nil
                if shouldBakeStems,
                   let outURL = outURLForBake,
                   let inURL = inURLForBake {
                    var blend = self.transitionDuration
                    let style = self.activeMashupStyle
                    let duetBake = self.transitionMode == .duet || style.isDuet
                    // Window is the musical outro, not the playhead while we prepare.
                    var cueA = max(0, musicalOutgoingCue ?? cueAForBake)
                    var cueB = max(0, startAt)
                    if !duetBake {
                        let heard = await self.retargetAutomixFromEnergy(
                            outgoingURL: outURL,
                            incomingURL: inURL,
                            playerDuration: self.duration > 1 ? self.duration : cueA + blend
                        )
                        if let heard {
                            cueA = heard.cueA
                            cueB = heard.cueB
                            blend = heard.blend
                        }
                    }
                    let handoffStyle = self.activeMashupStyle
                    let handoff = duetBake ? style.handoffAt : handoffStyle.automixLandProgress
                    // Extra tail so stems outlive bake lag + LAND handoff (short stems
                    // ending mid-window previously froze B after a stop/reload race).
                    // Tail must outlive bake lag. A short slice used to end, fire
                    // track-finish, and restart the next song from the top.
                    let stemPadSec = 8.0
                    let barSec = (4 * 60) / max(30, Double(style.targetBPM))
                    let loopSec = 0.0
                    // Apple Automix stems stay dry (carve only). Baked echo/plate
                    // is a third layer under live A+B and is what users hear as "troits".
                    let echoDelaySec = 0.0
                    let rateB = Double(style.rateB == 0 ? 1 : style.rateB)
                    // Bake in parallel with the cue wait. Waiting for HTDemucs first left
                    // 20s of silence after schedule, then a late abrupt land.
                    let bakeTask = Task.detached(priority: .userInitiated) { () -> (outgoing: URL, incoming: URL) in
                        do {
                            if let neural = try await HTDemucsMashupBake.stemPair(
                                duet: duetBake,
                                outgoingURL: outURL,
                                incomingURL: inURL,
                                cueA: cueA,
                                cueB: cueB,
                                blendSec: blend,
                                handoffProgress: handoff,
                                padSec: stemPadSec,
                                landFadeSec: barSec,
                                playbackRate: rateB,
                                loopSec: loopSec,
                                echoDelaySec: echoDelaySec
                            ) {
                                return neural
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Fall through to mid/side.
                        }
                        if duetBake {
                            return try MidSideStemBaker.bakeDuetStemPair(
                                outgoingURL: outURL,
                                incomingURL: inURL,
                                cueA: cueA,
                                cueB: cueB,
                                blendSec: blend,
                                padSec: stemPadSec
                            )
                        }
                        return try MidSideStemBaker.bakeAutomixStemPair(
                            outgoingURL: outURL,
                            incomingURL: inURL,
                            cueA: cueA,
                            cueB: cueB,
                            blendSec: blend,
                            handoffProgress: handoff,
                            padSec: stemPadSec,
                            landFadeSec: barSec,
                            playbackRate: rateB,
                            loopSec: loopSec,
                            echoDelaySec: echoDelaySec
                        )
                    }
                    // Decode + silent-arm B during lead-in so cue-time live Automix
                    // is instant and starve can hard-complete an already-playing B.
                    // Field starve: openAutomixPlaybackFile at the cue raced EOF.
                    let preparedIncoming = self.prepareMashupIncomingFile(inURL)
                    var prearmedIncoming = false
                    if let prepared = preparedIncoming {
                        AutoMixSessionLog.shared.event("lane.prepare ready before cue")
                        do {
                            try self.armPreparedMashupIncoming(
                                file: prepared,
                                on: targetNode,
                                at: cueB
                            )
                            prearmedIncoming = true
                        } catch {
                            AutoMixSessionLog.shared.fault(
                                "lane.arm \(error.localizedDescription)"
                            )
                        }
                    }
                    // Register cue for playhead ticks BEFORE waiting — field 1077
                    // never reached bake.pending because the prep wait never resumed.
                    self.pendingMashupLiveArm = PendingMashupLiveArm(
                        cueA: cueA,
                        cueB: cueB,
                        blend: blend,
                        handoff: handoff,
                        transitionID: transitionID,
                        generation: token,
                        currentTrackID: current.id,
                        inURL: inURL,
                        bakeTask: bakeTask,
                        prearmed: prearmedIncoming
                    )
                    self.firePendingMashupLiveArmIfNeeded()
                    if self.incomingLaneReady {
                        // Seek landed us already at/past the cue — mix is live.
                        self.transitionPreparationTask = nil
                        return
                    }
                    let reachedCue = await self.waitUntilMashupCue(cueA)
                    // Playhead tick may have started the mix while we waited.
                    if self.incomingLaneReady {
                        self.transitionPreparationTask = nil
                        return
                    }
                    guard reachedCue, !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                          self.isPlaying, self.currentTrack?.id == current.id, self.isTransitioning else {
                        AutoMixSessionLog.shared.event(
                            "cue.wait abort reached=\(reachedCue) cancel=\(Task.isCancelled)"
                        )
                        self.pendingMashupLiveArm = nil
                        bakeTask.cancel()
                        if let stemPair = try? await bakeTask.value {
                            MidSideStemBaker.removeTempFiles([stemPair.outgoing, stemPair.incoming])
                        }
                        return
                    }
                    // At the cue: take stems if ready, else start the live Automix now.
                    // Probe MUST NOT use a MainActor-isolated TaskGroup — both children
                    // serialized on MainActor and the 80ms timeout never won (field 1077).
                    enum BakeProbe {
                        case ready(Result<(outgoing: URL, incoming: URL), Error>)
                        case pending
                    }
                    let bakeProbe: BakeProbe = await withCheckedContinuation { cont in
                        final class ProbeBox: @unchecked Sendable {
                            var done = false
                        }
                        let box = ProbeBox()
                        let finish: @Sendable (BakeProbe) -> Void = { value in
                            Task { @MainActor in
                                guard !box.done else { return }
                                box.done = true
                                cont.resume(returning: value)
                            }
                        }
                        Task.detached {
                            try? await Task.sleep(for: .milliseconds(80))
                            finish(.pending)
                        }
                        Task.detached {
                            do {
                                finish(.ready(.success(try await bakeTask.value)))
                            } catch {
                                finish(.ready(.failure(error)))
                            }
                        }
                    }
                    // Land / cancel may have finished while we raced bake — never
                    // resurrect MIXING on a completed transition (field zombie badge).
                    guard !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                          self.isPlaying, self.currentTrack?.id == current.id, self.isTransitioning else {
                        bakeTask.cancel()
                        if case .ready(.success(let pair)) = bakeProbe {
                            MidSideStemBaker.removeTempFiles([pair.outgoing, pair.incoming])
                        } else if let stemPair = try? await bakeTask.value {
                            MidSideStemBaker.removeTempFiles([stemPair.outgoing, stemPair.incoming])
                        }
                        return
                    }
                    let bakeResult: Result<(outgoing: URL, incoming: URL), Error>
                    var bakePendingAtCue = false
                    switch bakeProbe {
                    case .ready(let result):
                        bakeResult = result
                    case .pending:
                        bakePendingAtCue = true
                        bakeResult = .failure(CocoaError(.fileReadUnknown))
                        // Prefer the shared playhead-fired path (idempotent).
                        if !self.incomingLaneReady {
                            if let arm = self.pendingMashupLiveArm {
                                arm.prearmed = prearmedIncoming || arm.prearmed
                                arm.fired = true
                                self.beginLiveAutomixAtCue(arm: arm)
                            } else {
                                self.mashupBakeFailedUseCrossfade = true
                                AutoMixSessionLog.shared.event("bake.pending → live Automix at cue")
                            }
                        }
                        if self.incomingLaneReady {
                            self.transitionPreparationTask = nil
                            return
                        }
                        // Arm failed — fall through to live FX fallback below.
                    }
                    let liveAfter = self.isUsingStreamPlayer ? self.progress : self.liveProgress()
                    // Only the time already past the cue belongs in the slice. Wall-clock
                    // bake time used to start the file 13s in, with 2s of audio left.
                    let heardPastCue = max(0, liveAfter - cueA)
                    let bakeLag = min(heardPastCue, max(0, blend - 1.5))
                    if case .failure(let bakeError) = bakeResult, !bakePendingAtCue {
                        self.mashupBakeFailedUseCrossfade = true
                        // Keep enough runway for echo/plate to read as a mix, not a cut.
                        self.transitionDuration = min(max(self.transitionDuration, 10), 14)
                        let extA = outURL.pathExtension
                        let extB = inURL.pathExtension
                        AutoMixSessionLog.shared.fault(
                            "bake.fail \(bakeError.localizedDescription) extA=\(extA) extB=\(extB) → live Automix FX"
                        )
                        SonivoDiagnostics.log(
                            "[Mashup] stem bake failed (\(extA)/\(extB)) — live Automix FX fallback: \(bakeError.localizedDescription)",
                            tag: "AUDIO"
                        )
                    }
                    if case .success(let stemPair) = bakeResult {
                        let landAtSec = blend * handoff
                        let remain = max(0, (self.duration > 1 ? self.duration : liveAfter + blend) - liveAfter)
                        let need = max(2.4, landAtSec - bakeLag)
                        // Separation finished after the downbeat, or the file itself
                        // ends before LAND. Playing the slice now runs it off the end
                        // and the next song restarts a few seconds in.
                        if bakeLag >= landAtSec - 1.2 || remain + 0.35 < need {
                            MidSideStemBaker.removeTempFiles([stemPair.outgoing, stemPair.incoming])
                            self.mashupBakeFailedUseCrossfade = true
                            self.transitionDuration = min(self.transitionDuration, 4)
                            SonivoDiagnostics.log(
                                "[Mashup] stems ready after LAND (\(String(format: "%.1f", bakeLag))s) — clean incoming",
                                tag: "AUDIO"
                            )
                            AutoMixSessionLog.shared.event(
                                String(format: "bake.late lag=%.2fs land=%.2fs", bakeLag, landAtSec)
                            )
                        } else {
                        self.clearMashupBakeTemps()
                        self.mashupBakeTempURLs = [stemPair.outgoing, stemPair.incoming]
                        self.mashupBakeRealIncomingURL = inURL
                        // Elapsed is measured from before the bake, so the cues stay
                        // the musical ones. Adding bakeLag here would skip ahead.
                        self.mashupBakeIncomingBaseCue = cueB
                        self.mashupBakeOutgoingBaseCue = cueA
                        self.mashupIncomingCueSec = cueB
                        // Keep musical cue B for timeline math; schedule offset is bakeLag only.
                        self.incomingStartPosition = cueB
                        try self.playMashupStemPair(
                            outgoingURL: stemPair.outgoing,
                            incomingURL: stemPair.incoming,
                            startOffsetSec: bakeLag
                        )
                        self.incomingLaneReady = true
                        let mixClock = Date()
                        // File position is already bakeLag into the slice. The fader
                        // must use that same clock or LAND fires after the slice ends.
                        self.transitionStartTime = mixClock.addingTimeInterval(-bakeLag)
                        // Remount the chrome/playhead clock onto track A (not bake file t=0).
                        // Stream observers stop after isUsingStreamPlayer flips false — start the
                        // native progress timer so NP/checkpoint keep advancing during MIXING.
                        self.anchorDate = mixClock
                        let heardA = cueA + bakeLag
                        self.anchorOffset = heardA
                        self.pausedProgress = heardA
                        self.progress = heardA
                        self.streamDuration = current.duration
                        self.startTimer()
                        // Stems already carved; volumes + rates stay live on the dual decks.
                        // Enter at bake-lag progress so Automix snaps locked rates/pitch
                        // (not the old accel-from-1.000 that field logs mistook for no beatmatch).
                        let enterP = min(1, bakeLag / max(0.001, blend))
                        let rates = self.activeMashupStyle.playbackRates(progress: enterP)
                        self.applyMashupTimePitch(progress: enterP, outgoing: true, rate: rates.outgoing)
                        self.applyMashupTimePitch(progress: enterP, outgoing: false, rate: rates.incoming)
                        self.applyMashupTransitionEQ(progress: enterP)
                        AutoMixDJEngine.shared.markMashupProgress(enterP)
                        AutoMixDJEngine.shared.currentBPM = Double(self.activeMashupStyle.targetBPM)
                        let sepLabel = HTDemucsMashupBake.lastBackend == "htdemucs"
                            ? "htdemucs"
                            : MidSideStemBaker.lastSeparationBackend.rawValue
                        AutoMixDJEngine.shared.statusBadge = sepLabel == "htdemucs"
                            ? "HTDemucs"
                            : self.activeMashupStyle.phaseLabel(progress: enterP)
                        let lockedA = self.activeMashupStyle.rateA
                        let lockedB = self.activeMashupStyle.rateB
                        let pitchB = self.activeMashupStyle.pitchCentsB
                        SonivoDiagnostics.log(
                            "[Mashup] \(duetBake ? "DUET" : "instr A + vocal B") dual-stem bake · A×\(String(format: "%.3f", lockedA)) B×\(String(format: "%.3f", lockedB)) pitchB=\(Int(pitchB))¢ · window \(String(format: "%.1f", blend))s · cueA \(String(format: "%.1f", cueA)) → cueB \(String(format: "%.1f", cueB))",
                            tag: "AUDIO"
                        )
                        AutoMixSessionLog.shared.event(
                            String(
                                format: "bake.ready %@ lag=%.2fs cueA=%.1f cueB=%.1f rateA=%.3f rateB=%.3f pitchB=%.0f bed=%.2f sep=%@",
                                duetBake ? "duet" : "automix",
                                bakeLag,
                                cueA,
                                cueB,
                                lockedA,
                                lockedB,
                                pitchB,
                                self.activeMashupStyle.automixIncomingBedGain,
                                sepLabel
                            )
                        )
                        self.startTransitionTimer()
                        self.transitionPreparationTask = nil
                        return
                        }
                    }
                }

                // Hold a skipped bake until the cue. A lead-in crossfade would
                // start the next song while the current one is still in the verse.
                if mashup {
                    let cue = max(0, musicalOutgoingCue ?? cueAForBake)
                    let reached = await self.waitUntilMashupCue(cue)
                    guard reached, !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                          self.isPlaying, self.currentTrack?.id == current.id, self.isTransitioning else { return }
                }

                // Prefer the local file already materialized for stem bake. Field 1045:
                // bake.fail left incomingIsStream=true while A was native → hybrid
                // crossfade with silent/stuck B (volB logged 0) then LAND freeze.
                let localIncomingURL = inURLForBake ?? nextURL
                var armedIncoming = false
                if let prepared = self.incomingAudioFile, !self.incomingIsStream {
                    do {
                        guard !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                              self.isPlaying, self.currentTrack?.id == current.id, self.isTransitioning else { return }
                        try self.armPreparedMashupIncoming(
                            file: prepared,
                            on: targetNode,
                            at: startAt
                        )
                        armedIncoming = true
                    } catch {
                        targetNode.stop()
                        targetNode.volume = 0
                        self.incomingAudioFile = nil
                        self.incomingIsStream = true
                        AutoMixSessionLog.shared.fault(
                            "fallback.file \(error.localizedDescription) → stream"
                        )
                    }
                } else if let localIncomingURL {
                    do {
                        // Private copy / CAF decode — the live m4a/mp3 open is what
                        // field-logged as bake.fail + fallback.file 'dta?' → stream.
                        let file = try self.openAutomixPlaybackFile(localIncomingURL)
                        guard !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                              self.isPlaying, self.currentTrack?.id == current.id, self.isTransitioning else { return }
                        try self.armPreparedMashupIncoming(
                            file: file,
                            on: targetNode,
                            at: startAt
                        )
                        armedIncoming = true
                    } catch {
                        // Same 'dta?' that killed the bake must not cancel the mix.
                        // The stream player can still ride the next song in.
                        targetNode.stop()
                        targetNode.volume = 0
                        self.incomingAudioFile = nil
                        self.incomingIsStream = true
                        AutoMixSessionLog.shared.fault(
                            "fallback.file \(error.localizedDescription) → stream"
                        )
                    }
                }
                if armedIncoming {
                    // Local deck is the incoming lane.
                } else if self.incomingIsStream {
                    let resolved: URL
                    var resolvedQuality: PlaybackQualityFacts?
                    let isCatalogTrack = YandexMusicService.ymId(fromFileName: nextTrack.fileName) != nil
                    if !isCatalogTrack, let direct = nextTrack.streamUrlString.flatMap(URL.init(string:)),
                       direct.scheme == "http" || direct.scheme == "https" {
                        resolved = direct
                    } else {
                        let info = try await YandexMusicService.shared.getStreamInfo(
                            for: Self.yandexTrackID(from: nextTrack), preferredQuality: self.audioQuality,
                            preferredBitrate: self.audioQuality.targetBitrate)
                        resolved = info.url
                        resolvedQuality = PlaybackQualityFacts(codec: info.codec, bitrate: info.bitrate)
                    }
                    guard !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                          self.isPlaying, self.currentTrack?.id == current.id, self.incomingTrack?.id == nextTrack.id,
                          self.isTransitioning else { return }
                    self.incomingQuality = resolvedQuality
                    if resolved.isFileURL && resolved.pathExtension.lowercased() == "flac" {
                        let file = try AVAudioFile(forReading: resolved)
                        guard file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                        self.incomingIsStream = false
                        self.incomingAudioFile = file
                        self.incomingQuality = LocalAudioQualityReader.read(file)
                        self.scheduleLocalSegment(file, on: targetNode, at: startAt)
                        targetNode.volume = 0
                        if !self.engine.isRunning { try self.engine.start() }
                        targetNode.play()
                    } else {
                        let item = AVPlayerItem(url: resolved)
                        item.audioTimePitchAlgorithm = .timeDomain
                        item.allowedAudioSpatializationFormats = self.spatialAudioEnabled ? .monoStereoAndMultichannel : []
                        StreamBeatTap.shared.attach(to: item)
                        targetStream.replaceCurrentItem(with: item)
                        targetStream.volume = 0
                        // Seek first, then play — playImmediately-then-seek often leaves B
                        // stalled at inCue (field log: frozen pos=16 after LAND).
                        let startRate = self.activeMashupStyle.playbackRates(progress: 0).incoming
                        let armID = transitionID
                        if startAt > 0.25 {
                            let seekTime = CMTime(seconds: startAt, preferredTimescale: 600)
                            targetStream.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                                Task { @MainActor [weak self] in
                                    guard let self, finished,
                                          self.transitionRequestID == armID,
                                          self.isTransitioning,
                                          self.idleStreamingPlayer.currentItem === item else { return }
                                    self.idleStreamingPlayer.playImmediately(atRate: startRate)
                                }
                            }
                        } else {
                            targetStream.playImmediately(atRate: startRate)
                        }
                    }
                } else {
                    let file = try AVAudioFile(forReading: nextTrack.url)
                    guard file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    guard !Task.isCancelled, self.generation == token, self.transitionRequestID == transitionID,
                          self.isPlaying, self.currentTrack?.id == current.id, self.isTransitioning else { return }
                    self.incomingAudioFile = file
                    self.incomingQuality = LocalAudioQualityReader.read(file)
                    self.scheduleLocalSegment(file, on: targetNode, at: startAt)
                    targetNode.volume = 0
                    if !self.engine.isRunning { try self.engine.start() }
                    targetNode.play()
                }
                self.incomingLaneReady = true
                self.transitionStartTime = Date()
                // Seed beatmatch + mashup EQ so the first frames already lock tempo / vocal bed.
                if self.isMashupTransitionMode {
                    if self.isUsingStreamPlayer, let item = self.activeStreamingPlayer.currentItem {
                        StreamBeatTap.shared.attach(to: item)
                    }
                    let rates = self.activeMashupStyle.playbackRates(progress: 0)
                    if self.isUsingStreamPlayer {
                        self.activeStreamingPlayer.rate = rates.outgoing
                    } else {
                        self.applyMashupTimePitch(progress: 0, outgoing: true, rate: rates.outgoing)
                    }
                    if self.incomingIsStream {
                        self.idleStreamingPlayer.rate = rates.incoming
                    } else {
                        self.applyMashupTimePitch(progress: 0, outgoing: false, rate: rates.incoming)
                    }
                    self.applyMashupTransitionEQ(progress: 0)
                    AutoMixDJEngine.shared.markMashupProgress(0)
                    AutoMixDJEngine.shared.currentBPM = Double(self.activeMashupStyle.targetBPM)
                    AutoMixDJEngine.shared.statusBadge = self.activeMashupStyle.phaseLabel(progress: 0)
                    SonivoDiagnostics.log(
                        "[Mashup] beatmatch A×\(String(format: "%.3f", rates.outgoing)) B×\(String(format: "%.3f", rates.incoming)) @\(Int(self.activeMashupStyle.targetBPM)) BPM · \(self.activeMashupStyle.reason)",
                        tag: "AUDIO"
                    )
                }
                self.startTransitionTimer()
                self.transitionPreparationTask = nil
            } catch {
                guard self.transitionRequestID == transitionID else { return }
                self.giveUpMashupAndKeepPlaying(error)
            }
        }
    }

    private func stopBeatLoop() {
        looperPlayer.stop()
        looperPlayer.volume = 0
        looperTimePitch.rate = 1.0
        loopBuffer = nil
        isLoopActive = false
    }

    private func AutoMixDJEngineCleanup() {
        incomingTrack = nil
        incomingLaneReady = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixDJEngine.shared.statusBadge = nil
        AutoMixDJEngine.shared.activeStrategyName = isMashupTransitionMode
            ? (activeMashupStyle.isDuet ? "DUET" : "MASHUP")
            : "GAPLESS"
        AutoMixDJEngine.shared.resetDrop()
        resetTransitionEQOffsets()
    }

    private func startTransitionTimer() {
        transitionTimer?.invalidate()
        // 60 Hz keeps mashup volumes / EQ envelopes continuous (30 Hz felt stepped).
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
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

        let mashup = isMashupTransitionMode
        // Offline A+B master already has volumes + stems summed — keep unity gain.
        if mashupPlayingMasterBake {
            clearLiveMixFX()
            if isUsingStreamPlayer {
                activeStreamingPlayer.volume = volume
            } else {
                activePlayer.volume = 1
            }
            idlePlayer.volume = 0
            idleStreamingPlayer.volume = 0
        } else {
            // Stem fail still keeps Automix character: EQ one-vocal + echo/plate + beatmatch.
            // Equal-power only avoids stacking two dry lead vocals when stems are missing.
            let useMashupVolumes = mashup && !mashupBakeFailedUseCrossfade
            let gains = useMashupVolumes
                ? mashupHeardVolumes(progress: p)
                : CrossfadeCurve.gains(progress: p)
            let gatedOutgoing: Float = mashup
                ? applyLivePlanFX(progress: p, elapsed: elapsed, outgoingVolume: gains.outgoing)
                : gains.outgoing
            let sourceLevel = gatedOutgoing
            let targetLevel = gains.incoming

            // Equal-power bridge: dry stream A → stem decks (avoids bake.ready thump).
            if mashup, let entryAt = mashupStemEntryStartedAt, mashupStemEntryFromStream {
                let entryT = min(1, max(0, -entryAt.timeIntervalSinceNow / max(0.05, mashupStemEntryDuration)))
                let ease = entryT * entryT * (3 - 2 * entryT)
                let streamOut = Float(cos(ease * Double.pi * 0.5))
                let stemIn = Float(sin(ease * Double.pi * 0.5))
                activeStreamingPlayer.volume = volume * streamOut * (sourceLevel > 0.001 ? 1 : 0)
                if isPlaying {
                    let rates = activeMashupStyle.playbackRates(progress: p)
                    activeStreamingPlayer.rate = rates.outgoing
                }
                activePlayer.volume = sourceLevel * stemIn
                idlePlayer.volume = targetLevel * stemIn
                if mashup {
                    let beatRates = activeMashupStyle.playbackRates(progress: p)
                    applyMashupTimePitch(progress: p, outgoing: true, rate: beatRates.outgoing)
                    applyMashupTimePitch(progress: p, outgoing: false, rate: beatRates.incoming)
                }
                if entryT >= 1 {
                    mashupStemEntryStartedAt = nil
                    mashupStemEntryFromStream = false
                    isUsingStreamPlayer = false
                    activeStreamingPlayer.pause()
                    activeStreamingPlayer.volume = 0
                    idleStreamingPlayer.pause()
                    idleStreamingPlayer.volume = 0
                }
                if mashup {
                    AutoMixDJEngine.shared.markMashupProgress(p)
                    AutoMixDJEngine.shared.currentBPM = Double(activeMashupStyle.targetBPM)
                    AutoMixDJEngine.shared.statusBadge = activeMashupStyle.phaseLabel(progress: p)
                    applyMashupTransitionEQ(progress: p)
                }
                if mashup, p >= activeMashupStyle.handoffAt, let incomingTrack {
                    completeTransition(to: incomingTrack)
                }
                return
            }

            let beatRates: (outgoing: Float, incoming: Float) = mashup
                ? activeMashupStyle.playbackRates(progress: p)
                : (outgoing: 1, incoming: 1)

            if isUsingStreamPlayer {
                activeStreamingPlayer.volume = sourceLevel * volume
                if mashup {
                    // Hold beatmatched tempo for A (not cosmetic ±1% wiggles).
                    activeStreamingPlayer.rate = isPlaying ? beatRates.outgoing : 0
                } else {
                    activeStreamingPlayer.rate = isPlaying ? 1.0 : 0
                }
            } else {
                activePlayer.volume = sourceLevel
                if mashup {
                    applyMashupTimePitch(progress: p, outgoing: true, rate: beatRates.outgoing)
                }
            }

            if incomingIsStream {
                idleStreamingPlayer.volume = targetLevel * volume
                if mashup {
                    idleStreamingPlayer.rate = isPlaying ? beatRates.incoming : 0
                } else {
                    idleStreamingPlayer.rate = isPlaying ? 1.0 : 0
                }
            } else {
                idlePlayer.volume = targetLevel
                if mashup {
                    applyMashupTimePitch(progress: p, outgoing: false, rate: beatRates.incoming)
                }
            }
        }

        // AutoMix Mashup: beatmatch + vocal↔instrumental layering on the beat grid.
        if mashup {
            AutoMixDJEngine.shared.markMashupProgress(p)
            AutoMixDJEngine.shared.currentBPM = Double(activeMashupStyle.targetBPM)
            AutoMixDJEngine.shared.statusBadge = activeMashupStyle.phaseLabel(progress: p)
            applyMashupTransitionEQ(progress: p)
        }

        // Apple Automix / Duet / Mashup: one hard cut at LAND — artwork, timeline,
        // and dry B switch together. No mid-mix timeline snap to a second clock.
        if mashup {
            // Use automixLandProgress (not raw handoffAt) so LAND waits for B bloom.
            let landAt = activeMashupStyle.isDuet
                ? activeMashupStyle.handoffAt
                : activeMashupStyle.automixLandProgress
            if p >= landAt, let incomingTrack {
                completeTransition(to: incomingTrack)
            }
        } else {
            let swapAt = 0.75
            if !metadataSwapped, let incomingTrack, p >= swapAt {
                metadataSwapped = true
                metadataTrack = incomingTrack
                NotificationCenter.default.post(
                    name: .didTriggerAutoMixDrop,
                    object: nil,
                    userInfo: ["trackID": incomingTrack.id.uuidString]
                )
            }
            if p >= 1.0, let incomingTrack {
                completeTransition(to: incomingTrack)
            }
        }
    }

    /// Beatmatch rate + Camelot pitch on native decks for the active mashup pair.
    private func applyMashupTimePitch(progress: Double, outgoing: Bool, rate: Float) {
        let node = outgoing ? activeTimePitch : idleTimePitch
        let cents = outgoing ? 0 : activeMashupStyle.pitchCents(progress: progress)
        let needsPitch = abs(cents) >= 0.5
        let needsRate = abs(rate - 1) >= 0.002
        node.bypass = !(needsPitch || needsRate)
        if needsRate || needsPitch {
            node.rate = rate
            node.pitch = cents
        }
    }

    private func clearMashupBakeTemps() {
        MidSideStemBaker.removeTempFiles(mashupBakeTempURLs)
        mashupBakeTempURLs = []
        mashupBakeRealIncomingURL = nil
        mashupBakeIncomingBaseCue = 0
        mashupBakeOutgoingBaseCue = 0
        mashupPlayingMasterBake = false
        mashupBakeFailedUseCrossfade = false
        mashupIncomingCueSec = 0
    }

    /// Play offline A+B master bake on the active native deck (idle stays silent).
    /// `startOffsetSec` skips bake latency so playback aligns with the live playhead.
    private func playMashupMasterBake(_ masterURL: URL, startOffsetSec: Double = 0) throws {
        let masterFile = try AVAudioFile(forReading: masterURL)
        guard masterFile.length > 0 else { throw CocoaError(.fileReadCorruptFile) }

        isUsingStreamPlayer = false
        incomingIsStream = false
        mashupPlayingMasterBake = true
        activeStreamingPlayer.pause()
        idleStreamingPlayer.pause()
        activeStreamingPlayer.volume = 0
        idleStreamingPlayer.volume = 0

        localSegmentTokens.removeValue(forKey: ObjectIdentifier(activePlayer))
        localSegmentTokens.removeValue(forKey: ObjectIdentifier(idlePlayer))
        activePlayer.stop()
        idlePlayer.stop()
        idlePlayer.volume = 0

        // Reset time-pitch — tempo is baked at natural file rates.
        activeTimePitch.rate = 1
        activeTimePitch.pitch = 0
        activeTimePitch.bypass = true
        idleTimePitch.rate = 1
        idleTimePitch.pitch = 0
        idleTimePitch.bypass = true

        let offset = max(0, startOffsetSec)
        activeAudioFile = masterFile
        incomingAudioFile = nil
        activeLocalURL = masterURL
        // Do not clobber musical cue B with the bake schedule offset.

        scheduleLocalSegment(masterFile, on: activePlayer, at: offset)
        activePlayer.volume = 1
        if !engine.isRunning { try engine.start() }
        activePlayer.play()
    }

    /// Lab dual-deck path: stem-baked A + B on separate nodes; rates/volumes stay live.
    private func playMashupStemPair(
        outgoingURL: URL,
        incomingURL: URL,
        startOffsetSec: Double = 0
    ) throws {
        let outFile = try AVAudioFile(forReading: outgoingURL)
        let inFile = try AVAudioFile(forReading: incomingURL)
        guard outFile.length > 0, inFile.length > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let fromStream = isUsingStreamPlayer
        mashupStemEntryFromStream = fromStream
        mashupStemEntryStartedAt = Date()
        // Long enough for the outgoing vocal to leave into the instrumental,
        // short enough that the dry song and the stem bed are not stacked.
        mashupStemEntryDuration = fromStream ? 0.32 : 0.08
        incomingIsStream = false
        mashupPlayingMasterBake = false
        if !fromStream {
            activeStreamingPlayer.pause()
            idleStreamingPlayer.pause()
            activeStreamingPlayer.volume = 0
            idleStreamingPlayer.volume = 0
            isUsingStreamPlayer = false
        } else {
            idleStreamingPlayer.pause()
            idleStreamingPlayer.volume = 0
            // Brief equal-power handoff from dry stream → stems (≤100 ms).
        }

        // Invalidate completions before stop so drained stems can't re-enter finish.
        localSegmentTokens.removeValue(forKey: ObjectIdentifier(activePlayer))
        localSegmentTokens.removeValue(forKey: ObjectIdentifier(idlePlayer))
        activePlayer.stop()
        idlePlayer.stop()

        let offset = max(0, startOffsetSec)
        activeAudioFile = outFile
        incomingAudioFile = inFile
        activeLocalURL = outgoingURL
        // Keep `incomingStartPosition` as musical cue B (set by beginTransition).

        scheduleLocalSegment(outFile, on: activePlayer, at: offset)
        scheduleLocalSegment(inFile, on: idlePlayer, at: offset)
        // Start stems silent; tickTransition ramps them over mashupStemEntryDuration.
        activePlayer.volume = 0
        idlePlayer.volume = 0
        if !engine.isRunning { try engine.start() }
        activePlayer.play()
        idlePlayer.play()
        if !fromStream {
            let vols = mashupHeardVolumes(
                progress: min(1, offset / max(0.001, transitionDuration))
            )
            activePlayer.volume = vols.outgoing
            idlePlayer.volume = vols.incoming
            mashupStemEntryStartedAt = nil
            isUsingStreamPlayer = false
        }
        if !activeMashupStyle.isDuet {
            mashupPhraseLoopCueSec = 0
            if liveLoopNextBar.isInfinite { liveLoopNextBar = 2 }
        }
    }

    /// Stem AutoMix keeps the ending instrumental under the next vocal.
    /// The older volume curve stays for a mix that is still two full files.
    private func mashupHeardVolumes(progress: Double) -> (outgoing: Float, incoming: Float) {
        if mashupBakeRealIncomingURL != nil, !mashupPlayingMasterBake {
            return activeMashupStyle.stemNeuralVolumes(progress: progress, blendSec: transitionDuration)
        }
        return activeMashupStyle.volumes(progress: progress)
    }

    private func completeTransition(to nextTrack: Track) {
        // Stem end + LAND timer used to call this twice: the second pass stopped
        // the freshly loaded B and swapped onto an empty idle node → frozen timecode.
        guard isTransitioning, !isCompletingTransition else { return }
        isCompletingTransition = true
        defer { isCompletingTransition = false }

        // Field 1076: starve→complete armed B, then the prep Task kept running and
        // logged bake.pending AFTER land — restarted MIXING with tx=0 / B=- and
        // left a zombie transitionTimer that hard-cut the next song 50ms in.
        transitionPreparationTask?.cancel()
        transitionPreparationTask = nil
        pendingMashupLiveArm = nil
        transitionRequestID = UUID()

        let elapsed = max(0, -(transitionStartTime ?? Date()).timeIntervalSinceNow)
        let usedBake = mashupBakeRealIncomingURL != nil
        // The stem file starts at cue B. Its playhead is the sample the listener
        // already heard — wall-clock elapsed used to land a few seconds further on.
        let stemFilePos = renderedFileSeconds(node: idlePlayer, file: incomingAudioFile)
        let fromStem = stemFilePos.map { max(0, mashupBakeIncomingBaseCue + $0) }
        // Local incoming was scheduled at incomingStartPosition; wall-clock elapsed alone would jump back to 0.
        // Baked slices start at 0 → map back onto the real track cue + elapsed.
        let nativeIncomingPosition = fromStem
            ?? (usedBake
                ? max(0, mashupBakeIncomingBaseCue + elapsed)
                : max(0, incomingStartPosition + elapsed))
        // Always hard-cut Automix/Duet at LAND (Apple Automix). Seamless stream swap
        // left B frozen at inCue when bake failed and the idle seek stalled.
        let mashupHardCut = isMashupTransitionMode
        let handoffPos = max(
            0,
            usedBake
                ? nativeIncomingPosition
                : (mashupIncomingCueSec > 0 ? mashupIncomingCueSec + elapsed : nativeIncomingPosition)
        )
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartTime = nil
        transitionScheduledAt = nil
        flushListeningStats()
        reportWaveFinishedIfNeeded()

        let wasStream = isUsingStreamPlayer

        if mashupHardCut {
            // Dry B immediately — leftover MixFX delay/plate made the next song double.
            clearLiveMixFX()
            // Reliable LAND: keep B stem audible while dry B mounts — stopping both
            // decks first left a silence gap that field users heard as an abrupt cut.
            NotificationCenter.default.post(
                name: .didTriggerAutoMixDrop,
                object: nil,
                userInfo: ["trackID": nextTrack.id.uuidString]
            )
            let landGuardUntil = Date().addingTimeInterval(2.0)
            suppressTrackFinishUntil = landGuardUntil
            suppressAutomixSkipUntil = landGuardUntil
            mashupStemEntryStartedAt = nil
            mashupStemEntryFromStream = false
            // Capture before clearing flags — bake-fail MIXING already has B on the
            // idle stream; promoting it avoids start()→cancelTransition()→reload races
            // that field-logged as ACTION next ~30ms after land.hardcut.
            let canPromoteIncomingStream = incomingIsStream
                && idleStreamingPlayer.currentItem != nil
            let realURL = mashupBakeRealIncomingURL
                ?? findLocalOrCachedAudioFile(for: nextTrack, respectingQuality: false)
            let safePos = safeAutomixHandoffPosition(for: nextTrack, proposed: handoffPos)
            // Hold B stem (idle) at unity while we prepare dry B on active.
            // Do NOT delete bake temps until after dry B is playing — deleting under
            // a live AVAudioFile read can glitch/cut the LAND.
            idlePlayer.volume = 1
            activeStreamingPlayer.pause()
            idleStreamingPlayer.pause()
            activeStreamingPlayer.volume = 0
            idleStreamingPlayer.volume = 0
            activeTimePitch.rate = 1
            activeTimePitch.pitch = 0
            activeTimePitch.bypass = true
            idleTimePitch.rate = 1
            idleTimePitch.pitch = 0
            idleTimePitch.bypass = true
            incomingTrack = nil
            incomingLaneReady = false
            incomingAudioFile = nil
            incomingIsStream = false
            prebufferedTrackId = nil
            plannedNextTrack = nil
            metadataTrack = nil
            metadataSwapped = false
            incomingQuality = nil
            isTransitioning = false
            transitionScheduled = false
            resetTransitionEQOffsets()
            let glideSec = activeMashupStyle.moodLand >= 0.85 ? 0.72 : 0.48
            activeMashupStyle = .fallback
            rateReleaseTimer?.invalidate()
            rateReleaseTimer = nil
            AutoMixDJEngine.shared.isTransitionActive = false
            AutoMixDJEngine.shared.transitionProgress = 0
            AutoMixDJEngine.shared.statusBadge = nil
            AutoMixDJEngine.shared.resetDrop()
            currentTrack = nextTrack
            streamDuration = nextTrack.duration
            currentCodec = nil
            currentBitrate = nil

            var handedOff = false
            var syncLocal = 0
            if let realURL {
                streamingPlayerA.pause()
                streamingPlayerB.pause()
                do {
                    try landAutomixOntoDryB(track: nextTrack, fileURL: realURL, at: safePos, glide: glideSec)
                    handedOff = true
                    syncLocal = 1
                } catch {
                    SonivoDiagnostics.log("[AutoMix] sync LAND handoff failed: \(error)", tag: "AUTOMIX")
                    localSegmentTokens.removeAll()
                    lyricsLocalSegments.removeAll()
                    activePlayer.stop()
                    idlePlayer.stop()
                    activePlayer.volume = 0
                    idlePlayer.volume = 0
                    do {
                        try handoffLocalPlayback(track: nextTrack, fileURL: realURL, at: safePos)
                        handedOff = true
                        syncLocal = 1
                    } catch {
                        SonivoDiagnostics.log("[AutoMix] LAND fallback handoff failed: \(error)", tag: "AUTOMIX")
                    }
                }
            }
            if landOverlapTimer == nil {
                clearMashupBakeTemps()
            }
            // Promote live incoming stream when local handoff is unavailable OR failed
            // (1045: syncLocal=0 + land.recover frozen after start() reload).
            if !handedOff, canPromoteIncomingStream {
                isUsingStreamPlayer = true
                let outgoingPlayer = activeStreamingPlayer
                let incomingPlayer = idleStreamingPlayer
                activeStreamingPlayer = incomingPlayer
                idleStreamingPlayer = outgoingPlayer
                outgoingPlayer.pause()
                outgoingPlayer.replaceCurrentItem(with: nil)
                outgoingPlayer.volume = 0
                outgoingPlayer.rate = 0
                activeStreamingPlayer.volume = volume
                let seekTime = CMTime(seconds: safePos, preferredTimescale: 600)
                activeStreamingPlayer.seek(
                    to: seekTime,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentTrack?.id == nextTrack.id else { return }
                        if self.isPlaying {
                            self.activeStreamingPlayer.playImmediately(atRate: 1.0)
                        }
                    }
                }
                if isPlaying {
                    activeStreamingPlayer.playImmediately(atRate: 1.0)
                }
                progress = safePos
                pausedProgress = safePos
                handedOff = true
                syncLocal = 2
            }
            if !handedOff {
                // Last resort: full start path. Preserve land guards across
                // start()→cancelTransition() so A-end / skipFailedWave cannot
                // jump past B.
                streamingPlayerA.pause()
                streamingPlayerB.pause()
                start(at: safePos)
                suppressTrackFinishUntil = landGuardUntil
                suppressAutomixSkipUntil = landGuardUntil
            }
            // Second clear after deck swap — B must stay dry (no leftover echo on next song).
            clearLiveMixFX()
            AutoMixDJEngine.shared.isPostMixActive = true
            SonivoDiagnostics.log(
                "[AutoMix] LAND hard-cut → \(nextTrack.title) @ \(String(format: "%.1f", safePos))s sync=\(syncLocal)",
                tag: "AUTOMIX"
            )
            AutoMixSessionLog.shared.event(
                String(
                    format: "land.hardcut B=%@ pos=%.1f proposed=%.1f syncLocal=%d glide=%.2f",
                    nextTrack.title,
                    safePos,
                    handoffPos,
                    syncLocal,
                    landOverlapTimer == nil ? 0 : glideSec
                )
            )
            lastNowPlayingSync = nil
            updateNowPlayingInfo()
            savePlaybackState()
            verifyAutomixHandoffPlayback(expected: nextTrack, at: safePos)
            return
        } else if incomingIsStream {
            if !wasStream {
                isUsingStreamPlayer = true
            }
            // Seamless swap: incoming player (already playing at full volume) continues undisturbed.
            // DO NOT reconfigure its audioTimePitchAlgorithm or rate while it's playing to prevent audio dropout/stutter!
            let outgoingPlayer = activeStreamingPlayer
            let incomingPlayer = idleStreamingPlayer
            activeStreamingPlayer = incomingPlayer
            idleStreamingPlayer = outgoingPlayer

            let hasIncomingItem = activeStreamingPlayer.currentItem != nil
            activeStreamingPlayer.volume = volume
            if isPlaying {
                activeStreamingPlayer.rate = 1.0
                activeStreamingPlayer.play()
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

            if !hasIncomingItem {
                // B never armed on the idle stream deck — hard start so LAND cannot hang.
                let safePos = safeAutomixHandoffPosition(for: nextTrack, proposed: handoffPos)
                currentTrack = nextTrack
                streamDuration = nextTrack.duration
                incomingTrack = nil
                incomingLaneReady = false
                isTransitioning = false
                transitionScheduled = false
                metadataTrack = nil
                metadataSwapped = false
                AutoMixDJEngine.shared.isTransitionActive = false
                AutoMixDJEngine.shared.transitionProgress = 0
                AutoMixDJEngine.shared.statusBadge = nil
                AutoMixDJEngine.shared.resetDrop()
                AutoMixDJEngine.shared.isPostMixActive = true
                suppressTrackFinishUntil = Date().addingTimeInterval(2.0)
                start(at: safePos)
                AutoMixSessionLog.shared.event("land.stream-fallback start @\(String(format: "%.1f", safePos))")
                lastNowPlayingSync = nil
                updateNowPlayingInfo()
                savePlaybackState()
                verifyAutomixHandoffPlayback(expected: nextTrack, at: safePos)
                return
            }
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
            // If idle never got a file (failed arm), hard-start B instead of promoting silence.
            if incomingAudioFile == nil {
                let safePos = safeAutomixHandoffPosition(for: nextTrack, proposed: handoffPos)
                currentTrack = nextTrack
                streamDuration = nextTrack.duration
                incomingTrack = nil
                incomingLaneReady = false
                isTransitioning = false
                transitionScheduled = false
                metadataTrack = nil
                metadataSwapped = false
                AutoMixDJEngine.shared.isTransitionActive = false
                AutoMixDJEngine.shared.transitionProgress = 0
                AutoMixDJEngine.shared.statusBadge = nil
                AutoMixDJEngine.shared.resetDrop()
                AutoMixDJEngine.shared.isPostMixActive = true
                suppressTrackFinishUntil = Date().addingTimeInterval(2.0)
                start(at: safePos)
                AutoMixSessionLog.shared.event("land.native-fallback start @\(String(format: "%.1f", safePos))")
                lastNowPlayingSync = nil
                updateNowPlayingInfo()
                savePlaybackState()
                verifyAutomixHandoffPlayback(expected: nextTrack, at: safePos)
                return
            }
            activePlayer = idlePlayer
            activeAudioFile = incomingAudioFile
            activeLocalURL = activeAudioFile?.url
            incomingAudioFile = nil
            activePlayer.volume = 1
            if isPlaying { activePlayer.play() }
            applyEQ()
        }

        incomingTrack = nil
        incomingLaneReady = false
        prebufferedTrackId = nil
        plannedNextTrack = nil
        currentTrack = nextTrack
        currentCodec = incomingQuality?.codec
        currentBitrate = incomingQuality?.bitrate
        incomingQuality = nil
        activeStreamURL = isUsingStreamPlayer ? (activeStreamingPlayer.currentItem?.asset as? AVURLAsset)?.url : nil
        metadataTrack = nil
        metadataSwapped = false
        streamDuration = nextTrack.duration

        // Sync playback progress accurately to the incoming player's actual continuous time
        let actualTime: Double
        if usedBake {
            actualTime = nativeIncomingPosition
        } else if isUsingStreamPlayer {
            actualTime = CMTimeGetSeconds(activeStreamingPlayer.currentTime())
        } else {
            actualTime = nativeIncomingPosition
        }
        let resolvedPos = (actualTime.isFinite && actualTime >= 0)
            ? actualTime
            : (usedBake ? nativeIncomingPosition : incomingStartPosition)
        anchorDate = Date()
        anchorOffset = resolvedPos
        pausedProgress = resolvedPos
        progress = resolvedPos

        isTransitioning = false
        transitionScheduled = false
        // Drop mashup EQ on both native decks and stream taps so the new track is clean.
        resetTransitionEQOffsets()
        activeMashupStyle = .fallback
        idleTimePitch.rate = 1.0
        idleTimePitch.pitch = 0
        idleTimePitch.bypass = true
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixDJEngine.shared.statusBadge = nil
        AutoMixDJEngine.shared.resetDrop()
        AutoMixDJEngine.shared.isPostMixActive = true
        SonivoDiagnostics.log(
            "[AutoMix] Transition completed (\(isMashupTransitionMode ? (activeMashupStyle.isDuet ? "duet" : "mashup") : "crossfade")): now playing \(nextTrack.title)",
            tag: "AUTOMIX"
        )

        if !isUsingStreamPlayer {
            startTimer()
            releaseActiveTimePitchToUnity()
        } else {
            stopTimer()
            activeAudioFile = nil
            activeLocalURL = nil
            localSegmentTokens.removeAll()
            lyricsLocalSegments.removeAll()
        }

        lastNowPlayingSync = nil
        updateNowPlayingInfo()
        savePlaybackState()
        verifyAutomixHandoffPlayback(
            expected: nextTrack,
            at: safeAutomixHandoffPosition(for: nextTrack, proposed: resolvedPos)
        )
        scheduleTransitionIfNeeded()
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
        if isTransitioning || transitionScheduled {
            AutoMixSessionLog.shared.event("transition.cancel")
        }
        clearLiveMixFX()
        transitionRequestID = UUID()
        transitionPreparationTask?.cancel()
        transitionPreparationTask = nil
        pendingMashupLiveArm = nil
        localSegmentTokens.removeValue(forKey: ObjectIdentifier(idlePlayer))
        transitionScheduled = false
        isTransitioning = false
        isCompletingTransition = false
        // Keep live LAND guards: start(at:) calls cancelTransition and used to
        // wipe suppressTrackFinishUntil, letting end-of-A notifications skip B.
        let finishGuard = suppressTrackFinishUntil
        let skipGuard = suppressAutomixSkipUntil
        let now = Date()
        suppressTrackFinishUntil = (finishGuard.map { $0 > now } == true) ? finishGuard : nil
        suppressAutomixSkipUntil = (skipGuard.map { $0 > now } == true) ? skipGuard : nil
        transitionTimer?.invalidate()
        transitionTimer = nil
        landOverlapToken = UUID()
        landOverlapTimer?.invalidate()
        landOverlapTimer = nil
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
        clearMashupBakeTemps()

        // Unconditionally silence and reset idle deck
        idleStreamingPlayer.pause()
        idleStreamingPlayer.replaceCurrentItem(with: nil)
        idleStreamingPlayer.volume = 0
        idleStreamingPlayer.rate = 0.0
        idlePlayer.stop()
        idlePlayer.volume = 0
        activePlayer.volume = 1
        activeStreamingPlayer.volume = volume
        activeStreamingPlayer.rate = isUsingStreamPlayer && isPlaying ? 1.0 : 0
        incomingAudioFile = nil
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixDJEngine.shared.statusBadge = nil
        AutoMixDJEngine.shared.resetDrop()
        AutoMixDJEngine.shared.isPostMixActive = false
        activeMashupStyle = .fallback
        resetTransitionEQOffsets()
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

    /// Stream clock stuck while the UI still says playing. A loose seek is enough
    /// to unstick AVPlayer after a pause; a zero-tolerance seek is what stuttered.
    func kickFrozenStreamIfNeeded() {
        guard isPlaying, !isTransitioning, isUsingStreamPlayer else { return }
        let player = activeStreamingPlayer
        let rate: Float = player.rate > 0.05 ? player.rate : 1
        let now = player.currentTime()
        player.seek(to: now, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) { _ in
            Task { @MainActor in
                guard PlayerCore.isSharedReady else { return }
                let core = PlayerCore.shared
                guard core.isPlaying, !core.isTransitioning, core.isUsingStreamPlayer else { return }
                core.activeStreamingPlayer.playImmediately(atRate: rate)
            }
        }
    }

    func nudgePlaybackAnchor(by drift: TimeInterval) {
        anchorOffset += drift
    }

    private func handleTrackFinish() {
        if let until = suppressTrackFinishUntil {
            if Date() < until {
                SonivoDiagnostics.log("[AutoMix] Ignoring track-finish during LAND handoff window", tag: "AUTOMIX")
                return
            }
            suppressTrackFinishUntil = nil
        }
        if isTransitioning || transitionScheduled {
            if let start = transitionStartTime, isMashupTransitionMode {
                let elapsed = -start.timeIntervalSinceNow
                let p = elapsed / max(0.001, transitionDuration)
                let land = activeMashupStyle.isDuet ? activeMashupStyle.handoffAt : activeMashupStyle.automixLandProgress
                if p < land - 0.04 {
                    // Only ignore A ending early when B is already carrying audio.
                    // Otherwise the room goes silent until LAND — field "song stops".
                    let bAlive = incomingIsStream
                        ? (idleStreamingPlayer.currentItem != nil && idleStreamingPlayer.rate > 0.05)
                        : idlePlayer.isPlaying
                    if bAlive {
                        SonivoDiagnostics.log(
                            "[AutoMix] Ignoring early segment end at \(String(format: "%.2f", p)) — B still playing",
                            tag: "AUTOMIX"
                        )
                        return
                    }
                    AutoMixSessionLog.shared.fault(
                        String(format: "transition.silent-early p=%.2f → force land/next", p)
                    )
                }
            }
            if transitionPreparationTask != nil, !incomingLaneReady {
                // B already decoded / queued but the fader never flipped ready —
                // hard-complete instead of starving into a cold start at t=0.
                let bArmed = incomingAudioFile != nil || idleStreamingPlayer.currentItem != nil
                if bArmed, let target = incomingTrack {
                    SonivoDiagnostics.log(
                        "[AutoMix] Track ended while preparing — complete armed B \(target.title)",
                        tag: "AUTOMIX"
                    )
                    AutoMixSessionLog.shared.fault("transition.starve → complete armed B")
                    completeTransition(to: target)
                    return
                }
                // A finished while bake/stream arm was still running. Returning here
                // left play=1 with a dead deck — the next song never started.
                SonivoDiagnostics.log(
                    "[AutoMix] Track ended while the mix is still preparing — force next",
                    tag: "AUTOMIX"
                )
                AutoMixSessionLog.shared.fault("transition.starve → next")
                giveUpMashupAndKeepPlaying(
                    NSError(
                        domain: "Sonivo.AutoMix",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Track ended before incoming lane was ready"]
                    )
                )
                return
            }
            if let target = incomingTrack, (incomingLaneReady || idleStreamingPlayer.currentItem != nil || incomingAudioFile != nil) {
                SonivoDiagnostics.log("[AutoMix] Track finished during transition: completing immediately to \(target.title)", tag: "AUTOMIX")
                completeTransition(to: target)
                return
            } else {
                SonivoDiagnostics.log("[AutoMix] Track finished but incoming lane was not ready. Forcing advance to next track.", tag: "AUTOMIX")
                AutoMixSessionLog.shared.fault("transition.lane-missing → next")
                let forced = incomingTrack ?? peekNext(auto: true)
                cancelTransition()
                if let forced {
                    currentTrack = forced
                    isPlaying = true
                    start(at: 0)
                    refillQueueIfNeeded()
                    return
                }
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

        if repeatMode == .one && !isYandexWavePlayback {
            start(at: 0)
            finishBgTask()
            return
        }
        if let nextTrack = peekNext(auto: true) {
            currentTrack = nextTrack
            start(at: 0)
            refillQueueIfNeeded()
            finishBgTask()
        } else if let current = currentTrack, (isYandexWavePlayback || repeatMode != .one) {
            let requestToken = generation, requestQueue = queueContinuationID
            Task { @MainActor in
                defer { finishBgTask() }
                let wave = await self.loadQueueContinuation(seed:current)
                guard self.generation == requestToken, self.queueContinuationID == requestQueue, self.currentTrack?.id == current.id, self.isPlaying else { return }
                if let ready = self.peekNext(auto:true) {
                    self.currentTrack = ready; self.streamDuration = ready.duration
                    self.start(at:0); self.refillQueueIfNeeded(); return
                }
                let existing = Set(self.queue.map(\.id))
                let fresh = wave.filter { !existing.contains($0.id) && $0.id != current.id && !self.waveRecovery.excludes(Self.yandexTrackID(from: $0)) }
                guard !fresh.isEmpty else {
                    self.playError = YandexMusicService.shared.waveError ?? (YandexMusicService.ymId(fromFileName:current.fileName) == nil
                        ? "Очередь закончилась. Для радио нужен трек из подключённого каталога."
                        : "Не удалось получить продолжение. Проверьте подключение и нажмите воспроизведение для повторной попытки.")
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
    private var waveListening = WaveListeningState()

    private func loadQueueContinuation(seed: Track) async -> [Track] {
        let ym = YandexMusicService.shared
        guard isYandexWavePlayback || MoodRadioEngine.shared.isTrackWaveActive || (ym.isUserLoggedIn && YandexMusicService.ymId(fromFileName:seed.fileName) != nil) else { return [] }
        let key = queueContinuationID.uuidString + ym.accountGeneration.uuidString
        let restoredStation = restoredWaveStation
        return await continuationLoader.load(key:key) {
            if ym.activeStationId == nil, let station = restoredStation {
                return await ym.startYandexWave(stationId: station).map { ym.convertToTrack($0) }
            } else if ym.activeStationId?.hasPrefix("track:") == true {
                return await ym.refillYandexTrackWave(target:25)
            } else if ym.activeStationId != nil {
                return await ym.refillYandexWave().map { ym.convertToTrack($0) }
            } else if MoodRadioEngine.shared.isTrackWaveActive {
                return await MoodRadioEngine.shared.refillTrackWaveQueue(target:25)
            } else {
                guard ym.isUserLoggedIn, YandexMusicService.ymId(fromFileName:seed.fileName) != nil else { return [] }
                return await ym.buildTrackWave(from:seed,target:20)
            }
        }
    }

    func refillQueueIfNeeded() {
        let ym = YandexMusicService.shared
        guard isPlaying, !isRefillingWave, (isYandexWavePlayback || repeatMode == .off), let current = currentTrack else { return }
        let now = Date()
        if let last = lastRefillCheck, now.timeIntervalSince(last) < 4.0 { return }
        let q = effectiveQueue()
        guard let currentIndex = q.firstIndex(where: { $0.id == current.id }) else { return }
        let remainingAhead = q.count - 1 - currentIndex
        // Do not start a new station halfway through a finite playlist. Prepare it during its last song.
        guard remainingAhead <= (isYandexWavePlayback ? 5 : 0) else { return }
        guard isYandexWavePlayback || MoodRadioEngine.shared.isTrackWaveActive || (ym.isUserLoggedIn && YandexMusicService.ymId(fromFileName:(q.last ?? current).fileName) != nil) else { return }
        lastRefillCheck = now; isRefillingWave = true
        let seed = q.last ?? current, queueID = queueContinuationID, account = ym.accountGeneration
        let sessionID = ym.rotorSessionID, stationBefore = ym.activeStationId
        let startingStation = stationBefore == nil
        Task { @MainActor [weak self] in
            defer { self?.isRefillingWave = false }
            guard let self, self.queueContinuationID == queueID, ym.accountGeneration == account, self.isPlaying else { return }
            let rawTracks = await self.loadQueueContinuation(seed:seed)
            guard self.queueContinuationID == queueID, ym.accountGeneration == account, self.isPlaying else { return }
            guard startingStation || (ym.rotorSessionID == sessionID && ym.activeStationId == stationBefore) else { return }
            let existing = Set(self.queue.map(\.id))
            var seen = existing
            let fresh = rawTracks.filter { $0.id != self.currentTrack?.id && !self.waveRecovery.excludes(Self.yandexTrackID(from: $0)) && seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { return }
            // Native server order, no local shuffle/reranking of a Yandex track station.
            self.queue.append(contentsOf:fresh)
            self.savePlaybackState()
            self.playError = nil
            if let next = self.peekNext(auto:true) { self.preloadArtwork(for:next) }
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

    private func recordWavePlaybackTick() {
        guard let track = currentTrack, track.isStream else { return }
        let id = Self.yandexTrackID(from: track)
        let advancing = isPlaying && (!isUsingStreamPlayer || activeStreamingPlayer.timeControlStatus == .playing)
        if waveListening.sample(trackID: id, position: progress, advancing: advancing) {
            YandexMusicService.shared.reportTrackStarted(trackId: id)
            YandexMusicService.shared.remember(key: track.id.uuidString, artist: track.artist, ymTrackId: id)
        }
        waveRecovery.heard(seconds: waveListening.seconds)
    }
    func reportWaveDislike(_ track: Track, isDisliked: Bool) {
        let id = Self.yandexTrackID(from: track)
        guard !id.isEmpty else { return }
        let seconds = waveListening.trackID == id ? waveListening.seconds : 0
        YandexMusicService.shared.reportWaveDislike(trackId: id, isDisliked: isDisliked, totalPlayedSeconds: seconds)
    }
    func finishWaveBeforeLeaving() { reportWaveSkipIfNeeded() }
    private func reportWaveSkipIfNeeded() {
        guard let track = currentTrack, track.isStream else { return }
        let id = Self.yandexTrackID(from: track)
        guard let seconds = waveListening.finish(trackID: id) else { return }
        YandexMusicService.shared.reportSkip(trackId: id, totalPlayedSeconds: seconds)
    }
    private func reportWaveFinishedIfNeeded() {
        guard let track = currentTrack, track.isStream else { return }
        let id = Self.yandexTrackID(from: track)
        guard let seconds = waveListening.finish(trackID: id) else { return }
        YandexMusicService.shared.reportTrackFinished(trackId: id, totalPlayedSeconds: seconds)
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
        let serverRadio = isYandexWavePlayback
        if shuffle && !serverRadio {
            if q.count == 1 { return repeatMode == .off && auto ? nil : q[0] }
            let candidates = q.filter { $0.id != currentTrack?.id }
            return candidates.randomElement()
        }
        guard let cur = currentTrack, let idx = q.firstIndex(where: { $0.id == cur.id }) else { return q.first }
        let nextIdx = idx + 1
        if nextIdx < q.count {
            if serverRadio {
                return q[nextIdx...].first { !waveRecovery.excludes(Self.yandexTrackID(from: $0)) }
            }
            return q[nextIdx]
        }
        if serverRadio { return nil }
        if repeatMode == .all { return q.first }
        if !auto, (!YandexMusicService.shared.isUserLoggedIn || YandexMusicService.ymId(fromFileName:cur.fileName) == nil) { return q.first }
        return nil
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
        recordWavePlaybackTick()
        checkpointPlaybackProgress()
        syncNowPlayingElapsedIfNeeded()
        firePendingMashupLiveArmIfNeeded()
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
        resetPlaybackFade(.sleep)
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

        let fadeSteps = 15
        let fadeDuration = 1.5
        let stepDelay = fadeDuration / Double(fadeSteps)

        let fadeGeneration = generation
        let fadeID = UUID()
        sleepFadeRequestID = fadeID
        let gainID = beginPlaybackFade(.sleep)
        sleepFadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.sleepFadeRequestID == fadeID {
                    self.endPlaybackFade(.sleep, id: gainID)
                    self.sleepFadeTask = nil
                }
            }
            for step in 1...fadeSteps {
                do { try await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, self.generation == fadeGeneration, self.isPlaying else { return }
                let fraction = Float(fadeSteps - step) / Float(fadeSteps)
                guard self.setPlaybackFade(.sleep, id: gainID, gain: fraction) else { return }
            }
            self.pause()
            self.endPlaybackFade(.sleep, id: gainID)
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
