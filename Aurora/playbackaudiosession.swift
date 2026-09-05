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

        // .allowBluetooth is an HFP/input option intended for playAndRecord.
        // Combining it with the playback category and long-form routing can
        // return kAudio_ParamError (-50), especially on newer iOS versions.
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: [.allowAirPlay]
            )
        } catch {
            report(error, step: "setCategory")
        }

        if usesV2 {
            do {
                try session.setPreferredSampleRate(DualDeckAudioEngine.preferredSampleRate)
            } catch {
                report(error, step: "setPreferredSampleRate")
            }

            do {
                try session.setPreferredIOBufferDuration(DualDeckAudioEngine.preferredIOBufferDuration)
            } catch {
                report(error, step: "setPreferredIOBufferDuration")
            }
        }

        do {
            try session.setActive(true)
        } catch {
            report(error, step: "setActive")
        }

        guard usesV2 else { return }

        let preferredRate = DualDeckAudioEngine.preferredSampleRate
        let preferredBuffer = DualDeckAudioEngine.preferredIOBufferDuration
        let actualRate = session.sampleRate
        let actualBuffer = session.ioBufferDuration
        let route = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")

        print("[AutoMix V2] audio session preferred=\(preferredRate)Hz/\(preferredBuffer)s actual=\(actualRate)Hz/\(actualBuffer)s route=\(route)")
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
                    message: "Configured route=\(route.isEmpty ? "none" : route) actual=\(actualRate)Hz/\(actualBuffer)s"
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
