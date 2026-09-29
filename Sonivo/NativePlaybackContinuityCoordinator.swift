@preconcurrency import AVFoundation
import Foundation
import UIKit

/// Keeps exactly one playback owner audible and preserves the current item when
/// the user changes between AutoMix V2 and NeuroMix. It also verifies native
/// audio output after the app is locked/backgrounded.
@MainActor
final class NativePlaybackContinuityCoordinator {
    static let shared = NativePlaybackContinuityCoordinator()

    private struct HandoffSnapshot {
        let track: Track
        let queue: [Track]
        let position: Double
        let wasPlaying: Bool
    }

    private var installed = false
    private var monitorTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var observedOwner: PlaybackOwner = .legacy
    private var lastSnapshot: HandoffSnapshot?
    private var lastBackgroundPosition: Double?
    private var stalledBackgroundTicks = 0

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true
        observedOwner = PlaybackCommandRouter.shared.owner
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.monitor()
                do { try await ContinuousClock().sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }

        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in
                    PlaybackAudioSessionCoordinator.shared.activateForPlayback()
                    try? await ContinuousClock().sleep(for: .milliseconds(180))
                    await self?.ensureSelectedEngineIsAudible()
                }
            })
        }
    }

    private func monitor() async {
        let owner = PlaybackCommandRouter.shared.owner
        if owner != observedOwner {
            let handoff = lastSnapshot
            observedOwner = owner
            try? await ContinuousClock().sleep(for: .milliseconds(220))
            await restore(handoff, to: owner)
        }

        if let snapshot = await snapshot(for: owner) {
            lastSnapshot = snapshot
        }

        guard UIApplication.shared.applicationState != .active else {
            lastBackgroundPosition = nil
            stalledBackgroundTicks = 0
            return
        }
        await monitorBackgroundProgress(owner: owner)
    }

    private func snapshot(for owner: PlaybackOwner) async -> HandoffSnapshot? {
        switch owner {
        case .legacy:
            guard let track = PlayerCore.shared.currentTrack else { return nil }
            return HandoffSnapshot(track: track,
                                   queue: PlayerCore.shared.queue,
                                   position: PlayerCore.shared.progress,
                                   wasPlaying: PlayerCore.shared.isPlaying)
        case .autoMixV2:
            let runtime = AutoMixV2Runtime.shared
            guard let track = runtime.currentTrack else { return nil }
            let timeline = await runtime.playbackTimeline()
            return HandoffSnapshot(track: track,
                                   queue: runtime.playbackQueue,
                                   position: timeline?.position ?? 0,
                                   wasPlaying: runtime.isPlaying)
        case .neuroMix:
            let runtime = NeuroMixRuntime.shared
            guard let track = runtime.currentTrack else { return nil }
            let timeline = await runtime.playbackTimeline()
            return HandoffSnapshot(track: track,
                                   queue: runtime.playbackQueue,
                                   position: timeline?.position ?? 0,
                                   wasPlaying: runtime.isPlaying)
        }
    }

    private func restore(_ snapshot: HandoffSnapshot?, to owner: PlaybackOwner) async {
        guard let snapshot else { return }
        let queue = snapshot.queue.isEmpty ? [snapshot.track] : snapshot.queue
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()

        switch owner {
        case .legacy:
            guard PlayerCore.shared.currentTrack?.id != snapshot.track.id else { return }
            PlayerCore.shared.play(snapshot.track, newQueue: queue)
            PlayerCore.shared.seek(to: snapshot.position)
            if !snapshot.wasPlaying { PlayerCore.shared.pause() }
        case .autoMixV2:
            if AutoMixV2Runtime.shared.currentTrack?.id != snapshot.track.id {
                guard await AutoMixV2Runtime.shared.play(snapshot.track, queue: queue) else { return }
                await AutoMixV2Runtime.shared.seek(to: snapshot.position)
            }
            if snapshot.wasPlaying { _ = await AutoMixV2Runtime.shared.play() }
            else { await AutoMixV2Runtime.shared.pause() }
        case .neuroMix:
            if NeuroMixRuntime.shared.currentTrack?.id != snapshot.track.id {
                guard await NeuroMixRuntime.shared.play(snapshot.track, queue: queue) else { return }
                await NeuroMixRuntime.shared.seek(to: snapshot.position)
            }
            if snapshot.wasPlaying { _ = await NeuroMixRuntime.shared.play() }
            else { await NeuroMixRuntime.shared.pause() }
        }
    }

    private func monitorBackgroundProgress(owner: PlaybackOwner) async {
        guard let snapshot = await snapshot(for: owner), snapshot.wasPlaying else {
            lastBackgroundPosition = nil
            stalledBackgroundTicks = 0
            return
        }
        if let previous = lastBackgroundPosition,
           snapshot.position <= previous + 0.01 {
            stalledBackgroundTicks += 1
        } else {
            stalledBackgroundTicks = 0
        }
        lastBackgroundPosition = snapshot.position
        if stalledBackgroundTicks >= 4 {
            stalledBackgroundTicks = 0
            PlaybackAudioSessionCoordinator.shared.activateForPlayback()
            await ensureSelectedEngineIsAudible()
        }
    }

    private func ensureSelectedEngineIsAudible() async {
        switch PlaybackCommandRouter.shared.owner {
        case .legacy:
            if PlayerCore.shared.isPlaying { PlayerCore.shared.resume() }
        case .autoMixV2:
            guard AutoMixV2Runtime.shared.isPlaying else { return }
            await AutoMixV2Runtime.shared.engineConfigurationChanged()
            _ = await AutoMixV2Runtime.shared.play()
        case .neuroMix:
            guard NeuroMixRuntime.shared.isPlaying else { return }
            await NeuroMixRuntime.shared.engineConfigurationChanged()
            _ = await NeuroMixRuntime.shared.play()
        }
    }
}
