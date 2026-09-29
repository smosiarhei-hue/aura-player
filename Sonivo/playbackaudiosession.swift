// Path: Sonivo/playbackaudiosession.swift

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
        // Wiring only — installing observers must never steal audio focus from another app.
        prepare()
        PlaybackCommandRouter.shared.install()
        AutoMixV2NowPlayingCenter.shared.install()

        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                switch type {
                case .began:
                    PlayerCore.shared.pause()
                case .ended:
                    PlaybackAudioSessionCoordinator.shared.prepare()
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                    if shouldResume {
                        PlayerCore.shared.resume()
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
                PlaybackAudioSessionCoordinator.shared.prepare()
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PlaybackAudioSessionCoordinator.shared.prepare()
            }
        })

        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PlaybackAudioSessionCoordinator.shared.prepare()
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PlaybackAudioSessionCoordinator.shared.prepare()
                PlayerCore.shared.resume()
            }
        })

        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PlaybackAudioSessionCoordinator.shared.prepare() }
        })

        // While Sonivo is backgrounded and silent it must not hold audio focus — that is
        // exactly what made it fight with other audio apps. Hand the session back so they
        // can play instead of being interrupted by us.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PlayerCore.shared.releaseAudioSessionIfIdle() }
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PlayerCore.shared.releaseAudioSessionIfIdle() }
        })
    }

    /// Category and hardware preferences only. Safe to call from any lifecycle event:
    /// it never claims audio focus, so it cannot interrupt another app that is playing.
    func prepare() {
        configure(activate: false)
    }

    /// Claims audio focus. Call only when sound is about to be produced.
    func activateForPlayback() {
        configure(activate: true)
    }

    /// Releases audio focus so other apps can resume. Callers must only reach this while
    /// Sonivo itself is silent.
    func deactivateWhenIdle() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            print("[Audio] session released; other apps may resume")
        } catch {
            // Already inactive, or interrupted by another app. Not worth surfacing.
        }
    }

    private func configure(activate: Bool) {
        let session = AVAudioSession.sharedInstance()
        let usesV2 = AutoMixEngineSelectionStore.shared.isV2Enabled || AutoMixEngineSelectionStore.shared.isNeuroEnabled
        let result = PlaybackAudioSessionSetup.configure(
            session: SystemPlaybackAudioSessionConfiguration(session: session),
            usesV2: usesV2,
            activateSession: activate
        ) { error, step in
            report(error, step: step.rawValue)
        }

        guard usesV2, (activate ? result.isActive : true) else { return }

        let actualRate = session.sampleRate
        let actualBuffer = session.ioBufferDuration
        let route = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")
        let spatialRoute = session.currentRoute.outputs
            .filter { $0.isSpatialAudioEnabled }
            .map(\.portName)
            .joined(separator: ", ")
        let spatialState = spatialRoute.isEmpty ? "off-or-unsupported" : "enabled:\(spatialRoute)"

        print("[Audio] session active actual=\(actualRate)Hz/\(actualBuffer)s route=\(route) spatial=\(spatialState)")
        Task {
            await AutoMixV2Runtime.shared.diagnostics.recordAudioSession(
                preferredSampleRate: actualRate,
                actualSampleRate: actualRate,
                preferredBufferDuration: actualBuffer,
                actualBufferDuration: actualBuffer
            )
            await AutoMixV2Runtime.shared.diagnostics.record(
                MixDiagnosticEvent(
                    category: "audio-session",
                    message: "Active route=\(route.isEmpty ? "none" : route) actual=\(actualRate)Hz/\(actualBuffer)s spatial=\(spatialState)"
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
