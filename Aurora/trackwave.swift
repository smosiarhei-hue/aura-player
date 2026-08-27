import Foundation

private struct TrackWaveCandidate {
    let item: YandexMusicService.YMTrackItem
    var score: Double
}

@MainActor
extension YandexMusicService {
    /// Builds a diverse queue related to the current song. The catalog remains
    /// the source of truth; the ranker combines track radio, artist similarity,
    /// album affinity, duration proximity and listening history.
    func buildTrackWave(from seed: Track, target: Int = 45) async -> [Track] {
        let seedID = Self.ymId(fromFileName: seed.fileName)
            ?? seed.streamUrlString?.replacingOccurrences(of: "ym_", with: "").replacingOccurrences(of: ".mp3", with: "")

        var candidates: [String: TrackWaveCandidate] = [:]
        var seedItem: YMTrackItem?

        func add(_ item: YMTrackItem, baseScore: Double, rank: Int = 0) {
            guard item.available != false else { return }
            if let seedID, item.id == seedID { return }
            if isRecentlyPlayed(ymTrackId: item.id) { return }

            var score = baseScore - Double(rank) * 0.65
            let normalizedSeedArtists = Set(
                seed.artist
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            )
            let candidateArtists = Set(
                (item.artists ?? [])
                    .compactMap { $0.name?.lowercased() }
            )
            if !normalizedSeedArtists.isDisjoint(with: candidateArtists) {
                score += 24
            }

            let seedAlbum = seed.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !seedAlbum.isEmpty,
               item.albums?.contains(where: { ($0.title ?? "").lowercased() == seedAlbum }) == true {
                score += 14
            }

            if seed.duration > 0, item.duration > 0 {
                let ratio = abs(seed.duration - item.duration) / max(seed.duration, item.duration)
                score += max(0, 10 * (1 - ratio))
            }

            // Stable tiny variation prevents identical queues while preserving relevance.
            let jitter = Double(item.id.utf8.reduce(0) { ($0 &* 31) &+ Int($1) } % 100) / 100
            score += jitter

            if let existing = candidates[item.id] {
                candidates[item.id] = TrackWaveCandidate(
                    item: item,
                    score: max(existing.score, score) + 5
                )
            } else {
                candidates[item.id] = TrackWaveCandidate(item: item, score: score)
            }
        }

        // 1. Native track radio is the strongest source of related candidates.
        if let seedID {
            let radio = (try? await getStationTracks(stationId: "track:\(seedID)")) ?? []
            for (index, item) in radio.enumerated() {
                add(item, baseScore: 120, rank: index)
            }
            seedItem = radio.first { $0.id == seedID }
        }

        // 2. Resolve exact catalog entity for artist and album affinity.
        if seedItem == nil {
            let query = "\(seed.artist) \(seed.title)"
            let search = await searchAllFixed(query: query)
            if let seedID {
                seedItem = search.tracks.first { $0.id == seedID }
            }
            if seedItem == nil {
                let title = seed.title.lowercased()
                seedItem = search.tracks.first { $0.title.lowercased() == title }
            }
            for (index, item) in search.tracks.prefix(12).enumerated() {
                add(item, baseScore: 58, rank: index)
            }
        }

        // 3. Popular songs by the seed artist and songs by similar artists.
        let artistIDs = (seedItem?.artists ?? []).compactMap { $0.id }.map(String.init)
        for artistID in artistIDs.prefix(2) {
            if let profile = try? await getArtistFixed(artistId: artistID) {
                for (index, item) in profile.popularTracks.prefix(16).enumerated() {
                    add(item, baseScore: 76, rank: index)
                }

                for similar in profile.similarArtists.prefix(5) {
                    let tracks = (try? await getArtistTracks(
                        artistId: similar.id,
                        page: 0,
                        pageSize: 12
                    )) ?? []
                    for (index, item) in tracks.enumerated() {
                        add(item, baseScore: 70, rank: index)
                    }
                }
            }
        }

        // 4. Personal wave fills sparse catalog responses without recent repeats.
        if candidates.count < target {
            let personal = await buildWaveQueue(
                stationId: waveMoodStationId,
                target: max(20, target - candidates.count)
            )
            for (index, item) in personal.enumerated() {
                add(item, baseScore: 42, rank: index)
            }
        }

        let sorted = candidates.values.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.item.id < right.item.id
        }

        var artistCounts: [String: Int] = [:]
        var result: [Track] = []
        for candidate in sorted {
            let primaryArtist = candidate.item.artists?.first?.name?.lowercased() ?? "unknown"
            guard artistCounts[primaryArtist, default: 0] < 3 else { continue }
            artistCounts[primaryArtist, default: 0] += 1
            result.append(convertToTrack(candidate.item))
            if result.count >= target { break }
        }

        return result
    }
}
