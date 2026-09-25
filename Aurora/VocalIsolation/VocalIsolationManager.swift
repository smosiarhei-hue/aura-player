// Path: Aurora/VocalIsolation/VocalIsolationManager.swift

import Foundation
import AVFoundation
import Observation

/// Thread-safe state accessible from audio render threads
nonisolated(unsafe) private var sharedIsolationLevel: Float = 0.0
nonisolated(unsafe) private var sharedProcessor: any VocalIsolationProcessing = MidSideVocalIsolator()

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
