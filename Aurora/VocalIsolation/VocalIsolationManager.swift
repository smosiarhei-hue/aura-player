// Path: Aurora/VocalIsolation/VocalIsolationManager.swift

@preconcurrency import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import Observation

/// Thread-safe state accessible from audio render threads
nonisolated(unsafe) private var sharedIsolationLevel: Float = 0.0
nonisolated(unsafe) private var sharedProcessor: any VocalIsolationProcessing = MidSideVocalIsolator()

/// Real-time CoreAudio render notify callback.
/// Invoked directly on CoreAudio's high-priority audio render thread on every audio buffer slice.
private let vocalIsolationCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
    guard let ioActionFlags,
          ioActionFlags.pointee.contains(.unitRenderAction_PostRender),
          let ioData else {
        return noErr
    }
    VocalIsolationManager.processAudioBufferList(ioData: ioData, frameCount: Int(inNumberFrames))
    return noErr
}

@Observable
@MainActor
final class VocalIsolationManager {
    static let shared = VocalIsolationManager()

    /// Whether vocal isolation processing is active
    var isEnabled: Bool = false {
        didSet {
            if !isEnabled {
                isolationLevel = 0.0
                isExpanded = false
            } else if isolationLevel == 0.0 {
                isolationLevel = 0.85 // Default sweet spot for karaoke vocal suppression
            }
            triggerStreamMigrationIfNeeded()
        }
    }

    /// Vocal isolation level: 0.0 (original mix) to 1.0 (vocal completely removed)
    /// Negative values (-1.0 .. 0.0) boost the vocal
    var isolationLevel: Float = 0.0 {
        didSet {
            let clamped = max(-1.0, min(1.0, isolationLevel))
            if isolationLevel != clamped {
                isolationLevel = clamped
            }
            if clamped > 0.01 && !isEnabled {
                isEnabled = true
            } else if clamped <= 0.001 && isEnabled && !isExpanded {
                isEnabled = false
            }
            triggerStreamMigrationIfNeeded()
        }
    }

    /// Whether the UI slider capsule is expanded or collapsed to compact icon
    var isExpanded: Bool = false

    /// Active DSP / ML algorithm conforming to VocalIsolationProcessing
    private(set) var processor: any VocalIsolationProcessing = MidSideVocalIsolator()

    private init() {}

    func setProcessor(_ newProcessor: any VocalIsolationProcessing) {
        self.processor = newProcessor
        sharedProcessor = newProcessor
    }

    /// Attaches the real-time DSP callback to any AVAudioUnit in an audio graph
    nonisolated func attach(to unit: AVAudioUnit) {
        let status = AudioUnitAddRenderNotify(unit.audioUnit, vocalIsolationCallback, nil)
        if status != noErr {
            SonivoDiagnostics.log("[VocalIsolation] AudioUnitAddRenderNotify status: \(status)", tag: "AUDIO")
        }
    }

    /// Fast audio processing callback callable from CoreAudio real-time tap or render thread
    nonisolated static func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let level = sharedIsolationLevel
        guard abs(level) > 0.001 else { return }
        guard let left = buffer.floatChannelData?[0],
              let right = (buffer.format.channelCount > 1 ? buffer.floatChannelData?[1] : buffer.floatChannelData?[0]) else {
            return
        }
        sharedProcessor.process(
            leftChannel: left,
            rightChannel: right,
            frameCount: Int(buffer.frameLength),
            isolationLevel: level
        )
    }

    /// In-place processing of CoreAudio AudioBufferList on post-render notification
    nonisolated static func processAudioBufferList(ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let level = sharedIsolationLevel
        guard abs(level) > 0.001, frameCount > 0 else { return }

        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        if abl.count >= 2,
           let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
           let right = abl[1].mData?.assumingMemoryBound(to: Float.self) {
            sharedProcessor.process(
                leftChannel: left,
                rightChannel: right,
                frameCount: frameCount,
                isolationLevel: level
            )
        } else if abl.count == 1,
                  abl[0].mNumberChannels >= 2,
                  let interleaved = abl[0].mData?.assumingMemoryBound(to: Float.self) {
            sharedProcessor.processInterleaved(
                samples: interleaved,
                frameCount: frameCount,
                isolationLevel: level
            )
        }
    }

    private func triggerStreamMigrationIfNeeded() {
        sharedIsolationLevel = isolationLevel
        guard isEnabled, isolationLevel > 0.05 else { return }

        // If currently playing through AVPlayer (streaming in PlayerCore),
        // migrate playback to AVAudioEngine so raw PCM samples are accessible in real-time.
        Task { @MainActor in
            await PlayerCore.shared.migrateStreamToAudioEngineIfNeeded()
        }
    }
}
