@preconcurrency import AVFoundation
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

        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            Task { @MainActor in
                guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    PlayerCore.shared.pause()
                case .ended:
                    PlaybackAudioSessionCoordinator.shared.configure()
                @unknown default:
                    break
                }
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt else { return }
            Task { @MainActor in
                guard AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) == .begin else { return }
                PlayerCore.shared.pause()
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            Task { @MainActor in
                guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                switch reason {
                case .newDeviceAvailable, .routeConfigurationChange, .categoryChange, .override:
                    PlaybackAudioSessionCoordinator.shared.configure()
                case .oldDeviceUnavailable:
                    PlayerCore.shared.pause()
                    PlaybackAudioSessionCoordinator.shared.configure()
                default:
                    break
                }
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PlaybackAudioSessionCoordinator.shared.configure()
            }
        })

        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PlaybackAudioSessionCoordinator.shared.configure()
            }
        })
    }

    func activateForPlayback() {
        configure()
    }

    private func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
        } catch {
            print("Playback audio session error: \(error)")
        }
    }
}
