import Foundation
import SwiftUI

// MARK: - User Taste & AI Wave Intelligence Engine
// Запоминает предпочтения пользователя: лайки (+5), прослушивания до конца (+3),
// быстрые пропуски (-2) и дизлайки (-10, исключение из волны).
// Позволяет 'Моей Волне' адаптироваться под индивидуальный вкус слушателя.

@Observable
final class UserTasteEngine: @unchecked Sendable {
    static let shared = UserTasteEngine()

    private let defaults = UserDefaults.standard
    private let dislikesKey = 'sonivo_disliked_tracks_v1'
    private let artistScoresKey = 'sonivo_artist_scores_v1'

    private(set) var dislikedTrackIDs: Set<String> = []
    private(set) var artistScores: [String: Double] = [:]

    init() {
        if let savedDislikes = defaults.stringArray(forKey: dislikesKey) {
            dislikedTrackIDs = Set(savedDislikes)
        }
        if let savedScores = defaults.dictionary(forKey: artistScoresKey) as? [String: Double] {
            artistScores = savedScores
        }
    }

    // MARK: - Actions

    func recordLike(track: Track) {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty {
            artistScores[artist, default: 0] += 5.0
            save()
        }
    }

    func recordDislike(track: Track) {
        dislikedTrackIDs.insert(track.id)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty {
            artistScores[artist, default: 0] -= 8.0
        }
        save()
    }

    func removeDislike(track: Track) {
        dislikedTrackIDs.remove(track.id)
        save()
    }

    func recordPlayback(track: Track, listenedSeconds: Double, totalDuration: Double) {
        guard totalDuration > 0 else { return }
        let ratio = listenedSeconds / totalDuration
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return }

        if ratio >= 0.75 {
            artistScores[artist, default: 0] += 3.0
        } else if ratio <= 0.15 && listenedSeconds < 20 {
            artistScores[artist, default: 0] -= 1.5
        }
        save()
    }

    func isDisliked(track: Track) -> Bool {
        dislikedTrackIDs.contains(track.id)
    }

    func filterAndRankWave(tracks: [Track]) -> [Track] {
        let available = tracks.filter { !dislikedTrackIDs.contains(.id) }
        return available.sorted { t1, t2 in
            let score1 = artistScores[t1.artist, default: 0]
            let score2 = artistScores[t2.artist, default: 0]
            return score1 > score2
        }
    }

    private func save() {
        defaults.set(Array(dislikedTrackIDs), forKey: dislikesKey)
        defaults.set(artistScores, forKey: artistScoresKey)
    }
}
