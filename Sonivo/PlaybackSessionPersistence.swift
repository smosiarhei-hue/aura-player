import Foundation
import UIKit

@MainActor
final class PlaybackSessionPersistence {
    static let shared = PlaybackSessionPersistence()
    private struct State: Codable { let queue: [Track]; let trackID: UUID; let position: Double }
    private let key = "automix.v2.last-session.v1"
    private var task: Task<Void, Never>?
    private var lastSavedData: Data?
    private init() {}

    func install() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await saveOrClear()
                do { try await ContinuousClock().sleep(for: .seconds(5)) } catch { return }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                object: nil, queue: .main) { _ in
            Task { @MainActor in await Self.shared.saveOrClear() }
        }
    }
    private func saveOrClear() async {
        let runtime = AutoMixV2Runtime.shared
        guard let track = runtime.currentTrack,
              let timeline = await runtime.playbackTimeline() else {
            if runtime.currentTrack == nil { UserDefaults.standard.removeObject(forKey: key) }
            return
        }
        let state = State(queue: runtime.playbackQueue, trackID: track.id, position: timeline.position)
        if let data = try? JSONEncoder().encode(state), data != lastSavedData {
            UserDefaults.standard.set(data, forKey: key)
            lastSavedData = data
        }
    }
}
