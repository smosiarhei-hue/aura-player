import AVFoundation
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
            Task { @MainActor in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                PlayerCore.shared.pause()
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main) { note in
            Task { @MainActor in
                guard let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
                      AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) == .begin else { return }
                PlayerCore.shared.pause()
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.configure() }
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
