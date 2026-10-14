import Foundation
import CoreHaptics
import AVFoundation
import UIKit
import Observation

/// Hardware work is serialized, never performed inside the audio tap or a view.
nonisolated final class MusicHapticsCore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sonivo.musichaptics", qos: .userInteractive)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var visualOverride = false
    private var engine: CHHapticEngine?
    private var running = false
    private var bodyPlayer: (any CHHapticAdvancedPatternPlayer)?
    private var lastBodyUpdate: TimeInterval = 0
    private var lastSignalAt: TimeInterval = 0
    private var kickBodyUntil: TimeInterval = 0
    private var watchdog: DispatchSourceTimer?

    private func ticket() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    private func permits(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == value && !visualOverride
    }
    func setVisualOverride(_ active: Bool) {
        lock.lock(); visualOverride=active; generation &+= 1; lock.unlock()
        queue.async { [weak self] in
            self?.silence(); self?.engine?.stop(); self?.running=false
        }
    }
    private func startEngine() -> CHHapticEngine? {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        do {
            if engine == nil {
                let value=try CHHapticEngine()
                value.playsHapticsOnly = true
                value.isAutoShutdownEnabled=true
                value.resetHandler = { [weak self] in
                    self?.queue.async { [weak self] in self?.running=false; self?.bodyPlayer=nil }
                }
                value.stoppedHandler = { [weak self] _ in
                    self?.queue.async { [weak self] in self?.running=false; self?.bodyPlayer=nil }
                }
                engine=value
            }
            if !running { try engine?.start(); running=true }
            return engine
        } catch { running=false; return nil }
    }
    private func armWatchdog() {
        guard watchdog == nil else { return }
        let timer=DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now()+0.05,repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date.timeIntervalSinceReferenceDate-self.lastSignalAt > 0.15 { self.silence() }
        }
        watchdog=timer; timer.resume()
    }
    private func silence() {
        try? bodyPlayer?.stop(atTime: CHHapticTimeImmediate)
        bodyPlayer=nil; lastBodyUpdate=0
        watchdog?.cancel(); watchdog=nil
    }
    func play(_ output: MusicHapticOutput) {
        let epoch=ticket(), submitted=Date.timeIntervalSinceReferenceDate
        queue.async { [weak self] in
            guard let self, self.permits(epoch), Date.timeIntervalSinceReferenceDate-submitted < 0.08 else { return }
            guard output.kick > 0 || output.treble > 0 || output.body > 0.005 else { self.silence(); return }
            guard let engine=self.startEngine() else { return }
            self.lastSignalAt=submitted
            do {
                if output.kick > 0 {
                    // One actuator: pause the sustained layer during the beat body.
                    // This avoids stacking soft + soft into a stronger-than-selected mix.
                    self.silence(); self.kickBodyUntil=submitted+0.085
                }
                if output.body > 0.005 && submitted >= self.kickBodyUntil {
                    if self.bodyPlayer == nil {
                        let event=CHHapticEvent(eventType: .hapticContinuous, parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity,value: 1),
                            // SharpnessControl is additive: base zero keeps it in range.
                            CHHapticEventParameter(parameterID: .hapticSharpness,value: 0)
                        ],relativeTime: 0,duration: 1)
                        let pattern=try CHHapticPattern(events: [event],parameters: [])
                        let player=try engine.makeAdvancedPlayer(with: pattern)
                        player.loopEnabled=true
                        try player.sendParameters([
                            CHHapticDynamicParameter(parameterID: .hapticIntensityControl,value: output.body,relativeTime: 0),
                            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,value: output.treble > 0 ? 0.85 : output.bodySharpness,relativeTime: 0)
                        ],atTime: CHHapticTimeImmediate)
                        try player.start(atTime: CHHapticTimeImmediate)
                        self.bodyPlayer=player; self.lastBodyUpdate=submitted
                    } else if submitted-self.lastBodyUpdate >= 0.04 || output.treble > 0 {
                        try self.bodyPlayer?.sendParameters([
                            CHHapticDynamicParameter(parameterID: .hapticIntensityControl,value: output.body,relativeTime: 0),
                            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,value: output.treble > 0 ? 0.85 : output.bodySharpness,relativeTime: 0)
                        ],atTime: CHHapticTimeImmediate)
                        self.lastBodyUpdate=submitted
                    }
                } else { self.silence() }
                if self.bodyPlayer != nil { self.armWatchdog() }
                var events: [CHHapticEvent]=[]
                if output.kick > 0 {
                    events.append(CHHapticEvent(eventType: .hapticTransient,parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity,value: min(1,output.kick)),
                        CHHapticEventParameter(parameterID: .hapticSharpness,value: 0.65)
                    ],relativeTime: 0))
                    events.append(CHHapticEvent(eventType: .hapticContinuous,parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity,value: min(1,output.kick)),
                        CHHapticEventParameter(parameterID: .hapticSharpness,value: 0.45)
                    ],relativeTime: 0.008,duration: 0.065))
                }
                if !events.isEmpty {
                    let player=try engine.makePlayer(with: CHHapticPattern(events: events,parameters: []))
                    try player.start(atTime: CHHapticTimeImmediate)
                }
            } catch { self.silence(); self.running=false }
        }
    }
    func playPreview(scale: Float, mode: MusicHapticsMode) {
        let epoch=ticket()
        queue.async { [weak self] in
            guard let self, self.permits(epoch), let engine=self.startEngine() else { return }
            self.silence()
            do {
                let events=[CHHapticEvent(eventType: .hapticTransient,parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity,value: scale),
                    CHHapticEventParameter(parameterID: .hapticSharpness,value: 0.65)
                ],relativeTime: 0),CHHapticEvent(eventType: .hapticContinuous,parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity,value: scale),
                    CHHapticEventParameter(parameterID: .hapticSharpness,value: 0.35)
                ],relativeTime: 0.16,duration: mode == .full ? 0.16 : 0.065)]
                let player=try engine.makePlayer(with: CHHapticPattern(events: events,parameters: []))
                try player.start(atTime: CHHapticTimeImmediate)
            } catch { self.running=false }
        }
    }
    func reset() { stop() }
    func stop() {
        lock.lock(); generation &+= 1; lock.unlock()
        queue.async { [weak self] in
            self?.silence(); self?.kickBodyUntil=0; self?.engine?.stop(); self?.running=false
        }
    }
}

/// Presentation clock owns vibration, independently of scrolling, Metal or refresh rate.
@Observable @MainActor
final class MusicHapticsManager {
    static let shared = MusicHapticsManager()
    nonisolated static let core = MusicHapticsCore()
    private var timeline=MusicHapticTimeline()
    private var signal=MusicHapticSignal()
    private var poll: Task<Void,Never>?
    private var lastClock: TimeInterval?
    private var lastDueAt: TimeInterval = 0
    private var previewUntil: TimeInterval = 0
    private var delayCheckedAt: TimeInterval = 0
    private var outputDelay: TimeInterval = 0
    private(set) var synchronization = "Ожидание аудиоданных"
    var supportsHaptics: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }
    private init() {}

    func submit(_ frame: BeatWaveAudioFrame) {
        guard supportsHaptics, SettingsStore.shared.musicHapticsEnabled,
              UIApplication.shared.applicationState == .active, PlayerCore.shared.isPlaying else { return }
        // Protected or unsupported streams without a PCM timestamp are not guessed.
        guard !PlayerCore.shared.usesStreamingBackend || frame.mediaTime != nil else {
            synchronization="Для этого потока нет таймкодов PCM"; return
        }
        timeline.push(frame)
        if poll == nil {
            poll=Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.tick()
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
        }
    }
    private func tick() {
        guard UIApplication.shared.applicationState == .active, SettingsStore.shared.musicHapticsEnabled,
              PlayerCore.shared.isPlaying else { stop(); return }
        let now=Date.timeIntervalSinceReferenceDate
        let deadline: TimeInterval
        if PlayerCore.shared.usesStreamingBackend {
            guard let clock=StreamBeatTap.shared.currentMediaClock(),clock.rate > 0 else {
                Self.core.stop(); signal.reset(); lastDueAt=0; return
            }
            deadline=clock.time; synchronization="Синхронизация по таймкодам аудио"
        } else {
            if now-delayCheckedAt > 1 {
                delayCheckedAt=now
                let session=AVAudioSession.sharedInstance()
                outputDelay=max(0,session.outputLatency+session.ioBufferDuration)
            }
            deadline=now-outputDelay; synchronization="Синхронизация по задержке аудиомаршрута"
        }
        if let previous=lastClock, deadline < previous-0.02 { reset(); return }
        lastClock=deadline
        let due=timeline.drain(at: deadline)
        var mix=MusicHapticOutput()
        var hasFresh=false
        for frame in due {
            let stamp=frame.mediaTime ?? frame.capturedAt
            guard deadline-stamp < 0.08 else { signal.reset(); continue }
            let output=signal.process(frame,ceiling: SettingsStore.shared.musicHapticsIntensity.scaleFactor,
                                      automatic: SettingsStore.shared.musicHapticsAutomatic, mode: SettingsStore.shared.musicHapticsMode)
            mix.kick=max(mix.kick,output.kick); mix.treble=max(mix.treble,output.treble); mix.body=output.body; mix.bodySharpness=output.bodySharpness
            hasFresh=true
        }
        if hasFresh {
            lastDueAt=now
            if now >= previewUntil { Self.core.play(mix) }
        } else if now >= previewUntil && now-lastDueAt > 0.1 {
            Self.core.stop(); signal.reset()
            synchronization="Ожидание новых аудиоданных"
        }
    }
    func playPreview(intensity: MusicHapticsIntensity) {
        guard UIApplication.shared.applicationState == .active, supportsHaptics else { return }
        previewUntil=Date.timeIntervalSinceReferenceDate+0.5
        Self.core.stop(); Self.core.playPreview(scale: intensity.scaleFactor, mode: SettingsStore.shared.musicHapticsMode)
    }
    func stop() {
        poll?.cancel(); poll=nil; timeline.reset(); signal.reset(); lastClock=nil; lastDueAt=0
        synchronization="Ожидание аудиоданных"; Self.core.stop()
    }
    func reset() { stop() }
}
