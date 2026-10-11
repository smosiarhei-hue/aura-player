import Foundation

nonisolated enum LibraryTrackFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all = "Все песни", favorites = "Избранное", playlists = "Плейлисты", recent = "Недавние"
    var id: String { rawValue }
}
nonisolated struct LibraryProjectionKey: Hashable, Sendable {
    let revision: UInt64
    let loggedIn: Bool
    let filter: LibraryTrackFilter
    let query: String
}
nonisolated struct LibraryTrackLookup: Sendable {
    private struct Entry: Sendable { let offset: Int; let track: Track }
    private var ids: [UUID: Entry] = [:]
    private var names: [String: Entry] = [:]
    init(_ tracks: [Track]) {
        for (offset, track) in tracks.enumerated() {
            let entry = Entry(offset: offset, track: track)
            if ids[track.id] == nil { ids[track.id] = entry }
            if !track.fileName.isEmpty && names[track.fileName] == nil { names[track.fileName] = entry }
        }
    }
    func matching(_ track: Track) -> Track? {
        let id = ids[track.id], name = track.fileName.isEmpty ? nil : names[track.fileName]
        if let id, let name { return id.offset <= name.offset ? id.track : name.track }
        return (id ?? name)?.track
    }
    func byID(_ id: UUID) -> Track? { ids[id]?.track }
}
nonisolated struct LibraryTrackProjection: Sendable {
    let key: LibraryProjectionKey
    let visible: [Track]
    let filtered: [Track]
    static func visibleOnly(_ tracks: [Track], loggedIn: Bool) throws -> [Track] {
        var result: [Track] = []; result.reserveCapacity(tracks.count)
        for track in tracks {
            try Task.checkCancellation()
            if loggedIn || (!track.isStream && FileManager.default.fileExists(atPath: track.url.path)) { result.append(track) }
        }
        return result
    }
    static func build(_ tracks: [Track], key: LibraryProjectionKey) throws -> Self {
        let visible = try visibleOnly(tracks, loggedIn: key.loggedIn)
        let lookup = LibraryTrackLookup(tracks)
        var filtered = visible
        switch key.filter {
        case .all, .playlists: break
        case .favorites: filtered = filtered.filter { $0.isFavorite || lookup.matching($0)?.isFavorite == true }
        case .recent: filtered = Array(filtered.sorted { $0.addedAt > $1.addedAt }.prefix(30))
        }
        if !key.query.isEmpty {
            filtered = filtered.filter {
                $0.title.localizedCaseInsensitiveContains(key.query) || $0.artist.localizedCaseInsensitiveContains(key.query) || $0.album.localizedCaseInsensitiveContains(key.query)
            }
        }
        try Task.checkCancellation()
        return Self(key: key, visible: visible, filtered: filtered)
    }
}
