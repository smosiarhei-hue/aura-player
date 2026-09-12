import Foundation
import UIKit

@MainActor
final class PlaybackSessionPersistence {
    static let shared = PlaybackSessionPersistence()
    private struct State: Codable { let queue: [Track]; let trackID: UUID; let position: Double }
    private let key = "automix.v2.last-session.v1"
    private var task: Task<Void, Never>?
    private init() {}

    func install() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if AutoMixEngineSelectionStore.shared.isV2Enabled {
                PlayerCore.shared.stopAndClear()
                await restore()
            }
            while !Task.isCancelled {
                await saveOrClear()
                do { try await ContinuousClock().sleep(for: .seconds(1)) } catch { return }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                object: nil, queue: .main) { _ in
            Task { @MainActor in await Self.shared.saveOrClear() }
        }
    }
    private func restore() async {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(State.self, from: data),
              let track = state.queue.first(where: { $0.id == state.trackID }) else { return }
        await AutoMixV2Runtime.shared.play(track, queue: state.queue)
        await AutoMixV2Runtime.shared.seek(to: max(0, state.position))
        await AutoMixV2Runtime.shared.pause()
    }
    private func saveOrClear() async {
        let runtime = AutoMixV2Runtime.shared
        guard let track = runtime.currentTrack,
              let timeline = await runtime.playbackTimeline() else {
            if runtime.currentTrack == nil { UserDefaults.standard.removeObject(forKey: key) }
            return
        }
        let state = State(queue: runtime.playbackQueue, trackID: track.id, position: timeline.position)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: key) }
    }
}
