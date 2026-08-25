import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var tracks: [Track] = [] { didSet { persist() } }
    @Published private(set) var isScanning = false
    @Published var importProgress: Double? = nil
    @Published var lastError: String? = nil

    static let indexURL: URL = {
        documentsDirectoryURL().appendingPathComponent("library.json")
    }()

    private init() {
        load()
        Task { await rescan() }
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let saved = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracks = saved
    }

    // MARK: - Scan local storage (Documents and Documents/Music)

    func rescan() async {
        isScanning = true
        defer { isScanning = false }

        let exts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac", "ogg", "caf"]
        let docURL = documentsDirectoryURL()
        let musicURL = musicDirectoryURL()

        var discoveredURLs: [URL] = []

        // 1. Scan Documents root (where Finder / iTunes / Files app puts files)
        if let rootFiles = try? FileManager.default.contentsOfDirectory(at: docURL, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            for file in rootFiles {
                let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir && exts.contains(file.pathExtension.lowercased()) {
                    discoveredURLs.append(file)
                }
            }
        }

        // 2. Scan Documents/Music subdirectory
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
        let targetDir = musicDirectoryURL()

        for url in urls {
            let isScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isScoped { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let dest = targetDir.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                try await addLocalFile(at: dest)
            } catch {
                lastError = "Не удалось импортировать: \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Import from URL (Direct Download)

    func importFromURL(_ link: String) async {
        lastError = nil
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            lastError = "Некорректная ссылка на аудиофайл"
            return
        }

        importProgress = -1
        defer { importProgress = nil }

        do {
            let (tmpUrl, response) = try await URLSession.shared.download(from: url)
            var filename = url.lastPathComponent
            if filename.isEmpty || !filename.contains(".") {
                let mime = (response as? HTTPURLResponse)?.mimeType ?? ""
                let ext = mime.contains("mp4") || mime.contains("m4a") ? "m4a" : (mime.contains("flac") ? "flac" : "mp3")
                filename = "track_\(Int(Date().timeIntervalSince1970)).\(ext)"
            }

            let dest = musicDirectoryURL().appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmpUrl, to: dest)
            try await addLocalFile(at: dest)
        } catch {
            lastError = "Ошибка скачивания: \(error.localizedDescription)"
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

    // MARK: - Favorites & Deletion

    func toggleFavorite(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].isFavorite.toggle()
    }

    func delete(_ track: Track) {
        if PlayerCore.shared.currentTrack?.id == track.id {
            PlayerCore.shared.stopAndClear()
        }
        if !track.isStream {
            try? FileManager.default.removeItem(at: track.url)
            let cacheArt = Self.artworkURL(for: track.id)
            try? FileManager.default.removeItem(at: cacheArt)
        }
        tracks.removeAll { $0.id == track.id }
    }

    func resetIndex() {
        tracks.removeAll()
        try? FileManager.default.removeItem(at: Self.indexURL)
    }

    // MARK: - Artwork Cache

    static func artworkURL(for trackId: UUID) -> URL {
        artworkCacheDirectoryURL().appendingPathComponent("\(trackId.uuidString).jpg")
    }

    static func cachedArtworkImage(for track: Track) -> UIImage? {
        let tempSeed = stableSeed(track.fileName)
        let artPath = artworkCacheDirectoryURL().appendingPathComponent("seed_\(tempSeed).jpg")
        guard FileManager.default.fileExists(atPath: artPath.path) else { return nil }
        return UIImage(contentsOfFile: artPath.path)
    }

    // MARK: - Metadata Extraction

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
            if let t = first(.commonIdentifierTitle), !t.trimmingCharacters(in: .whitespaces).isEmpty {
                title = t
            }
            if let a = first(.commonIdentifierArtist), !a.trimmingCharacters(in: .whitespaces).isEmpty {
                artist = a
            }
            if let alb = first(.commonIdentifierAlbumName), !alb.trimmingCharacters(in: .whitespaces).isEmpty {
                album = alb
            }

            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = item.dataValue, let image = UIImage(data: data) {
                hasArtwork = true
                colors = artworkPalette(from: image)

                // Cache the image to disk
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

    // MARK: - Vibrant Palette Extraction

    nonisolated private static func artworkPalette(from image: UIImage) -> [String] {
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

        let top = buckets.enumerated()
            .sorted { $0.element > $1.element }
            .prefix(4)

        var hexes: [String] = []
        for (idx, _) in top where buckets[idx] > 0 {
            let cnt = Double(buckets[idx])
            let hh = hueSum[idx] / cnt
            let ss = min(1.0, max(0.5, satSum[idx] / cnt + 0.2))
            let vv = min(0.85, max(0.4, briSum[idx] / cnt))
            let rgb = hsvToRGB(h: hh, s: ss, v: vv)
            hexes.append(String(format: "#%02X%02X%02X",
                                Int(rgb.0 * 255), Int(rgb.1 * 255), Int(rgb.2 * 255)))
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
