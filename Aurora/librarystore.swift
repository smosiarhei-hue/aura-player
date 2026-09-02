import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import Observation

@Observable
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var tracks: [Track] = [] { didSet { persistTracks() } }
    private(set) var playlists: [Playlist] = [] { didSet { persistPlaylists() } }
    private(set) var isScanning = false
    /// True while a local file-picker import is copying/reading files, so the
    /// UI can show a spinner instead of looking like nothing happened.
    private(set) var isImportingFiles = false
    var importProgress: Double? = nil
    var lastError: String? = nil

    static let tracksIndexURL: URL = {
        documentsDirectoryURL().appendingPathComponent("library_tracks.json")
    }()

    static let playlistsIndexURL: URL = {
        documentsDirectoryURL().appendingPathComponent("library_playlists.json")
    }()

    private init() {
        loadData()
        Task {
            await rescan()
        }
    }

    // MARK: - Persistence

    private func persistTracks() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: Self.tracksIndexURL, options: .atomic)
        }
    }

    private func persistPlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: Self.playlistsIndexURL, options: .atomic)
        }
    }

    private func loadData() {
        if let data = try? Data(contentsOf: Self.tracksIndexURL),
           let saved = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = saved
        }
        if let pData = try? Data(contentsOf: Self.playlistsIndexURL),
           let savedPlaylists = try? JSONDecoder().decode([Playlist].self, from: pData) {
            playlists = savedPlaylists
        }
    }

    // MARK: - Playlists Management

    func createPlaylist(title: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let gradients = [
            ["#FF455B", "#9333EA"],
            ["#F97316", "#E11D48"],
            ["#06B6D4", "#3B82F6"],
            ["#10B981", "#6366F1"],
            ["#EC4899", "#F59E0B"]
        ]
        let p = Playlist(title: title, coverGradient: gradients.randomElement() ?? ["#FF455B", "#9333EA"])
        playlists.insert(p, at: 0)
    }

    func addTrackToPlaylist(track: Track, playlistId: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        // Ensure track is in library
        if !tracks.contains(where: { $0.id == track.id }) {
            tracks.append(track)
        }
        if !playlists[idx].trackIds.contains(track.id) {
            playlists[idx].trackIds.append(track.id)
            persistPlaylists()
        }
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
    }

    func tracks(for playlist: Playlist) -> [Track] {
        let set = Set(playlist.trackIds)
        return tracks.filter { set.contains($0.id) }
    }

    // MARK: - Favorites (Works for BOTH local and online tracks!)

    var favorites: [Track] {
        tracks.filter { $0.isFavorite }
    }

    func toggleFavorite(_ track: Track) {
        if let i = tracks.firstIndex(where: { $0.id == track.id || ($0.fileName == track.fileName && !track.fileName.isEmpty) }) {
            tracks[i].isFavorite.toggle()
        } else {
            // Track is an online stream or not yet saved -> add to library as favorite!
            var newFavorite = track
            newFavorite.isFavorite = true
            tracks.insert(newFavorite, at: 0)
        }
    }

    func isTrackFavorite(_ track: Track) -> Bool {
        if let found = tracks.first(where: { ($0.fileName == track.fileName && !track.fileName.isEmpty) || $0.id == track.id }) {
            return found.isFavorite
        }
        return false
    }

    func isTrackInLibrary(_ track: Track) -> Bool {
        tracks.contains { ($0.fileName == track.fileName && !track.fileName.isEmpty) || $0.id == track.id }
    }

    // MARK: - Scan local storage (Documents, Music, and Media Library)

    func rescan() async {
        isScanning = true
        defer { isScanning = false }

        let exts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac", "ogg", "caf"]
        let docURL = documentsDirectoryURL()
        let musicURL = musicDirectoryURL()

        var discoveredURLs: [URL] = []

        if let rootFiles = try? FileManager.default.contentsOfDirectory(at: docURL, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            for file in rootFiles {
                let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir && exts.contains(file.pathExtension.lowercased()) {
                    discoveredURLs.append(file)
                }
            }
        }

        if let musicFiles = try? FileManager.default.contentsOfDirectory(at: musicURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in musicFiles {
                if exts.contains(file.pathExtension.lowercased()) && !discoveredURLs.contains(where: { $0.lastPathComponent == file.lastPathComponent }) {
                    discoveredURLs.append(file)
                }
            }
        }

        let knownNames = Set(tracks.filter { !$0.isStream }.map(\.fileName))
        var addedTracks: [Track] = []

        for url in discoveredURLs where !knownNames.contains(url.lastPathComponent) {
            let meta = await Self.readMetadata(url: url)
            let seed = Self.stableSeed(url.lastPathComponent)
            let relative = url.path.replacingOccurrences(of: docURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            let track = Track(
                fileName: url.lastPathComponent,
                relativePath: relative,
                title: meta.title,
                artist: meta.artist,
                album: meta.album,
                duration: meta.duration,
                artworkSeed: seed,
                colorsHex: meta.colors,
                hasEmbeddedArtwork: meta.hasArtwork
            )
            addedTracks.append(track)
        }

        if !addedTracks.isEmpty {
            tracks.append(contentsOf: addedTracks)
        }
    }

    // MARK: - Import from File Picker (Security-Scoped URLs)

    func importFromPicker(urls: [URL]) {
        Task { await importFiles(from: urls) }
    }

    func importFiles(from urls: [URL]) async {
        lastError = nil
        guard !urls.isEmpty else { return }
        isImportingFiles = true
        defer { isImportingFiles = false }

        let targetDir = musicDirectoryURL()
        var failures: [String] = []

        for url in urls {
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let dest = targetDir.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                try await addLocalFile(at: dest)
                SonivoDiagnostics.log("Imported local file: \(url.lastPathComponent)", tag: "LIBRARY")
            } catch {
                // Surface the real underlying reason (permission denied, file
                // not found, iCloud file not downloaded, etc.) instead of a
                // generic message - this is what previously made a failed
                // import look like it silently did nothing.
                SonivoDiagnostics.log("Import failed for \(url.lastPathComponent): \(error.localizedDescription)", tag: "LIBRARY")
                failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            lastError = failures.count == 1
                ? "Не удалось импортировать «\(failures[0])»"
                : "Не удалось импортировать \(failures.count) файл(ов):\n" + failures.joined(separator: "\n")
        }
    }

    /// Dismiss the currently shown import error. Kept as an explicit method
    /// (rather than a public setter) because `lastError` itself stays
    /// private(set) like the rest of this store's published state.
    func clearLastError() {
        lastError = nil
    }

    // MARK: - Save Online Track for Offline Playback

    func saveOnlineTrackLocally(track: Track) async {
        guard track.isStream, let urlString = track.streamUrlString, let url = URL(string: urlString) else { return }
        lastError = nil
        importProgress = -1
        defer { importProgress = nil }

        do {
            let (tmpUrl, _) = try await URLSession.shared.download(from: url)
            let safeTitle = track.title.replacingOccurrences(of: "/", with: "-")
            let safeArtist = track.artist.replacingOccurrences(of: "/", with: "-")
            let destName = "\(safeArtist) - \(safeTitle).mp3"
            let dest = musicDirectoryURL().appendingPathComponent(destName)

            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmpUrl, to: dest)
            try await addLocalFile(at: dest)
        } catch {
            lastError = "Не удалось сохранить трек: \(error.localizedDescription)"
        }
    }

    // MARK: - Add Local File

    func addLocalFile(at dest: URL) async throws {
        let meta = await Self.readMetadata(url: dest)
        let docURL = documentsDirectoryURL()
        let relative = dest.path.replacingOccurrences(of: docURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let track = Track(
            fileName: dest.lastPathComponent,
            relativePath: relative,
            title: meta.title,
            artist: meta.artist,
            album: meta.album,
            duration: meta.duration,
            artworkSeed: Self.stableSeed(dest.lastPathComponent),
            colorsHex: meta.colors,
            hasEmbeddedArtwork: meta.hasArtwork
        )

        tracks.removeAll { $0.fileName == track.fileName }
        tracks.insert(track, at: 0)
    }

    func delete(_ track: Track) {
        if PlayerCore.shared.currentTrack?.id == track.id {
            PlayerCore.shared.stopAndClear()
        }
        if !track.isStream {
            try? FileManager.default.removeItem(at: track.url)
        }
        tracks.removeAll { $0.id == track.id }
        for i in playlists.indices {
            playlists[i].trackIds.removeAll { $0 == track.id }
        }
    }

    func resetIndex() {
        tracks.removeAll()
        playlists.removeAll()
        try? FileManager.default.removeItem(at: Self.tracksIndexURL)
        try? FileManager.default.removeItem(at: Self.playlistsIndexURL)
    }

    // MARK: - Artwork Cache

    static func cachedArtworkImage(for track: Track) -> UIImage? {
        let tempSeed = stableSeed(track.fileName)
        let artPath = artworkCacheDirectoryURL().appendingPathComponent("seed_\(tempSeed).jpg")
        guard FileManager.default.fileExists(atPath: artPath.path) else { return nil }
        return UIImage(contentsOfFile: artPath.path)
    }

    nonisolated private static func readMetadata(url: URL) async -> (
        title: String, artist: String, album: String, duration: Double, colors: [String], hasArtwork: Bool
    ) {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Неизвестный исполнитель"
        var album = ""
        var duration = 0.0
        var colors: [String] = []
        var hasArtwork = false

        if let meta = try? await asset.load(.commonMetadata) {
            func first(_ id: AVMetadataIdentifier) -> String? {
                AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first?.stringValue
            }
            if let t = first(.commonIdentifierTitle), !t.trimmingCharacters(in: .whitespaces).isEmpty { title = t }
            if let a = first(.commonIdentifierArtist), !a.trimmingCharacters(in: .whitespaces).isEmpty { artist = a }
            if let alb = first(.commonIdentifierAlbumName), !alb.trimmingCharacters(in: .whitespaces).isEmpty { album = alb }

            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = item.dataValue, let image = UIImage(data: data) {
                hasArtwork = true
                colors = artworkPalette(from: image)
                let tempSeed = stableSeed(url.lastPathComponent)
                let artPath = artworkCacheDirectoryURL().appendingPathComponent("seed_\(tempSeed).jpg")
                if let jpg = image.jpegData(compressionQuality: 0.85) {
                    try? jpg.write(to: artPath)
                }
            }
        }

        if let dur = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(dur)
            if s.isFinite && s > 0 { duration = s }
        }

        return (title, artist, album, duration, colors, hasArtwork)
    }

    nonisolated static func artworkPalette(from image: UIImage) -> [String] {
        let size = 16
        guard let cg = image.cgImage else { return [] }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)

        let drawn = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return [] }

        var buckets = [Int](repeating: 0, count: 12)
        var hueSum = [Double](repeating: 0, count: 12)
        var satSum = [Double](repeating: 0, count: 12)
        var briSum = [Double](repeating: 0, count: 12)

        for i in 0..<(size * size) {
            let r = Double(pixels[i * 4]) / 255.0
            let g = Double(pixels[i * 4 + 1]) / 255.0
            let b = Double(pixels[i * 4 + 2]) / 255.0
            var h = 0.0, s = 0.0, v = 0.0
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            v = mx; s = mx == 0 ? 0 : d / mx
            if d > 0 {
                if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
                else if mx == g { h = (b - r) / d + 2 }
                else { h = (r - g) / d + 4 }
                h *= 60; if h < 0 { h += 360 }
            }
            let bucket = min(11, max(0, Int(h / 30)))
            let w = Int(s * s * 10) + 1
            buckets[bucket] += w
            hueSum[bucket] += Double(w) * h
            satSum[bucket] += Double(w) * s
            briSum[bucket] += Double(w) * v
        }

        let top = buckets.enumerated().sorted { $0.element > $1.element }.prefix(4)
        var hexes: [String] = []
        for (idx, _) in top where buckets[idx] > 0 {
            let cnt = Double(buckets[idx])
            let hh = hueSum[idx] / cnt
            let ss = min(1.0, max(0.5, satSum[idx] / cnt + 0.2))
            let vv = min(0.85, max(0.4, briSum[idx] / cnt))
            let rgb = hsvToRGB(h: hh, s: ss, v: vv)
            hexes.append(String(format: "#%02X%02X%02X", Int(rgb.0 * 255), Int(rgb.1 * 255), Int(rgb.2 * 255)))
        }
        return hexes
    }

    nonisolated private static func hsvToRGB(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let c = v * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        var rgb: (Double, Double, Double) = (0, 0, 0)
        switch hp {
        case ..<1: rgb = (c, x, 0)
        case ..<2: rgb = (x, c, 0)
        case ..<3: rgb = (0, c, x)
        case ..<4: rgb = (0, x, c)
        case ..<5: rgb = (x, 0, c)
        default:   rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }

    nonisolated static func stableSeed(_ s: String) -> Int {
        var hash: UInt64 = 5381
        for b in s.utf8 { hash = (hash << 5) &+ hash &+ UInt64(b) }
        return Int(hash % 1000000)
    }
}
