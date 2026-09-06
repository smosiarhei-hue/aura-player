// Path: Aurora/playbackaudiosession.swift

@preconcurrency import AVFoundation
import AudioEngineCore
import MixDiagnostics
import UIKit

@MainActor
final class PlaybackAudioSessionCoordinator {
    static let shared = PlaybackAudioSessionCoordinator()

    private var installed = false
    private var observers: [NSObjectProtocol] = []

    func install() {
        guard !installed else { return }
        installed = true
        configure()
        PlaybackCommandRouter.shared.install()

        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                switch type {
                case .began:
                    if AutoMixEngineSelectionStore.shared.isV2Enabled {
                        await AutoMixV2Runtime.shared.interruptionBegan()
                    } else {
                        PlayerCore.shared.pause()
                    }
                case .ended:
                    PlaybackAudioSessionCoordinator.shared.configure()
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                    if AutoMixEngineSelectionStore.shared.isV2Enabled {
                        await AutoMixV2Runtime.shared.interruptionEnded(shouldResume: shouldResume)
                    }
                @unknown default:
                    break
                }
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            Task { @MainActor in
                guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                if reason == .oldDeviceUnavailable {
                    PlaybackCommandRouter.shared.pause()
                }
                PlaybackAudioSessionCoordinator.shared.configure()
            }
        })

        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard AutoMixEngineSelectionStore.shared.isV2Enabled else { return }
                await AutoMixV2Runtime.shared.engineConfigurationChanged()
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PlaybackAudioSessionCoordinator.shared.configure()
                if AutoMixEngineSelectionStore.shared.isV2Enabled {
                    await AutoMixV2Runtime.shared.engineConfigurationChanged()
                }
            }
        })

        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PlaybackAudioSessionCoordinator.shared.configure() }
        })
    }

    func activateForPlayback() {
        configure()
    }

    private func configure() {
        let session = AVAudioSession.sharedInstance()
        let usesV2 = AutoMixEngineSelectionStore.shared.isV2Enabled
        let result = PlaybackAudioSessionSetup.configure(
            session: SystemPlaybackAudioSessionConfiguration(session: session),
            usesV2: usesV2
        ) { error, step in
            report(error, step: step.rawValue)
        }

        // Never publish an active/configured snapshot after category or activation failure.
        guard result.isActive, usesV2 else { return }

        let preferredRate = DualDeckAudioEngine.preferredSampleRate
        let preferredBuffer = DualDeckAudioEngine.preferredIOBufferDuration
        let actualRate = session.sampleRate
        let actualBuffer = session.ioBufferDuration
        let rejectedPreferences = result.failedSteps.map(\.rawValue).joined(separator: ", ")
        let preferenceStatus = rejectedPreferences.isEmpty ? "none" : rejectedPreferences
        let route = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")

        print("[AutoMix V2] audio session active preferred=\(preferredRate)Hz/\(preferredBuffer)s actual=\(actualRate)Hz/\(actualBuffer)s rejectedPreferences=\(preferenceStatus) route=\(route)")
        Task {
            await AutoMixV2Runtime.shared.diagnostics.recordAudioSession(
                preferredSampleRate: preferredRate,
                actualSampleRate: actualRate,
                preferredBufferDuration: preferredBuffer,
                actualBufferDuration: actualBuffer
            )
            await AutoMixV2Runtime.shared.diagnostics.record(
                MixDiagnosticEvent(
                    category: "audio-session",
                    message: "Active route=\(route.isEmpty ? "none" : route) actual=\(actualRate)Hz/\(actualBuffer)s rejectedPreferences=\(preferenceStatus)"
                )
            )
        }
    }

    private func report(_ error: Error, step: String) {
        let message = "\(step) failed: \(error.localizedDescription)"
        print("[AutoMix V2] audio session \(message)")
        guard AutoMixEngineSelectionStore.shared.isV2Enabled else { return }
        Task {
            await AutoMixV2Runtime.shared.diagnostics.record(
                MixDiagnosticEvent(level: .error, category: "audio-session", message: message)
            )
        }
    }
}
