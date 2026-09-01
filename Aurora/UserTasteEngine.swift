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
    private let dislikesKey = "sonivo_disliked_tracks_v1"
    private let artistScoresKey = "sonivo_artist_scores_v1"

    private(set) var dislikedTrackIDs: Set<UUID> = []
    private(set) var artistScores: [String: Double] = [:]

    init() {
        if let savedDislikes = defaults.stringArray(forKey: dislikesKey) {
            dislikedTrackIDs = Set(savedDislikes.compactMap { UUID(uuidString: $0) })
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

    /// Ranks a wave queue by taste but stays non-deterministic: equal-score
    /// artists are shuffled each session, artists are spread out so the same
    /// performer never stacks at the top, and tracks that already opened a
    /// recent wave are demoted so two sessions never start identically.
    func filterAndRankWave(tracks: [Track]) -> [Track] {
        let available = tracks.filter { !dislikedTrackIDs.contains($0.id) }
        guard available.count > 1 else { return available }

        // Fisher-Yates shuffle first: inside a taste tier the order rotates.
        var pool = available
        for index in stride(from: pool.count - 1, through: 1, by: -1) {
            let swap = Int.random(in: 0...index)
            pool.swapAt(index, swap)
        }

        let openerPenalty = Set(recentWaveOpeners.prefix(12))
        let scored = pool.map { track -> (track: Track, score: Double) in
            var score = artistScores[track.artist, default: 0]
            if openerPenalty.contains(track.id.uuidString) { score -= 2.5 }
            return (track, score)
        }

        // Stable sort by score: high taste wins, ties keep their fresh shuffle.
        let sorted = scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return false
        }

        // Spread artists: max 2 in a row from the same performer.
        var result: [Track] = []
        var taken = Set<UUID>()
        var streakArtist: String?
        var streakCount = 0
        var cursor = 0

        while result.count < sorted.count {
            guard cursor < sorted.count else { break }
            let entry = sorted[cursor]
            if taken.contains(entry.track.id) {
                cursor += 1
                continue
            }
            let artist = entry.track.artist
            if artist == streakArtist, streakCount >= 2 {
                // Find the next candidate from a different artist.
                if let alternative = sorted.firstIndex(where: { !taken.contains($0.track.id) && $0.track.artist != artist }) {
                    let pick = sorted[alternative]
                    taken.insert(pick.track.id)
                    result.append(pick.track)
                    streakArtist = pick.track.artist
                    streakCount = 1
                    continue
                }
            }
            taken.insert(entry.track.id)
            result.append(entry.track)
            streakCount = (artist == streakArtist) ? streakCount + 1 : 1
            streakArtist = artist
            cursor += 1
        }

        rememberWaveOpeners(result)
        return result
    }

    // MARK: - Wave opener rotation

    private let openersKey = "sonivo_wave_openers_v1"

    private var recentWaveOpeners: [String] {
        defaults.stringArray(forKey: openersKey) ?? []
    }

    private func rememberWaveOpeners(_ queue: [Track]) {
        let ids = queue.prefix(4).map(\.id.uuidString)
        var merged = ids + recentWaveOpeners
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0).inserted }
        defaults.set(Array(merged.prefix(24)), forKey: openersKey)
    }

    private func save() {
        defaults.set(dislikedTrackIDs.map(\.uuidString), forKey: dislikesKey)
        defaults.set(artistScores, forKey: artistScoresKey)
    }
}
