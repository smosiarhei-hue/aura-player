import AVFoundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var tracks: [Track] = [] { didSet { persist() } }
    @Published private(set) var isScanning = false
    @Published var importProgress: Double? = nil
    @Published var lastError: String? = nil

    static let indexURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("library.json")
    }()

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    private init() {
        load()
        Task { await rescan() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let saved = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracks = saved
    }

    // MARK: - Scan existing files in Music directory

    func rescan() async {
        isScanning = true
        defer { isScanning = false }
        let exts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac", "ogg"]
        let files = (try? FileManager.default.contentsOfDirectory(at: musicDirectoryURL(), includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { exts.contains($0.pathExtension.lowercased()) } ?? []

        let known = Set(tracks.map(\.fileName))
        var added: [Track] = []
        for url in files where !known.contains(url.lastPathComponent) {
            let meta = await Self.readMetadata(url: url)
            let t = Track(
                fileName: url.lastPathComponent,
                title: meta.title,
                artist: meta.artist,
                album: meta.album,
                duration: meta.duration,
                artworkSeed: Self.stableSeed(url.lastPathComponent),
                colorsHex: meta.colors
            )
            added.append(t)
        }
        guard !added.isEmpty else { return }
        tracks.append(contentsOf: added)
    }

    // MARK: - Import from file picker (security-scoped URLs)

    func importFromPicker(urls: [URL]) {
        Task { await importFiles(from: urls) }
    }

    func importFiles(from urls: [URL]) async {
        lastError = nil
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let dest = musicDirectoryURL().appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                try await addFile(at: dest)
            } catch {
                lastError = "Импорт не удался: \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Import from URL (direct download)

    func importFromURL(_ link: String) async {
        lastError = nil
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            lastError = "Некорректная ссылка"
            return
        }
        importProgress = -1  // indeterminate
        defer { importProgress = nil }
        do {
            let (tmpUrl, _) = try await URLSession.shared.download(from: url)
            let name = url.lastPathComponent.isEmpty ? "track-\(Int(Date().timeIntervalSince1970)).mp3" : url.lastPathComponent
            let dest = musicDirectoryURL().appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpUrl, to: dest)
            try await addFile(at: dest)
        } catch {
            lastError = "Скачивание не удалось: \(error.localizedDescription)"
        }
    }

    // MARK: - Add single file to library

    func addFile(at dest: URL) async throws {
        let meta = await Self.readMetadata(url: dest)
        let track = Track(
            fileName: dest.lastPathComponent,
            title: meta.title,
            artist: meta.artist,
            album: meta.album,
            duration: meta.duration,
            artworkSeed: Self.stableSeed(dest.lastPathComponent),
            colorsHex: meta.colors
        )
        if !tracks.contains(where: { $0.fileName == track.fileName }) {
            tracks.append(track)
        }
    }

    // MARK: - Favorites / Delete / Reset

    func toggleFavorite(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].isFavorite.toggle()
    }

    func delete(_ track: Track) {
        if PlayerCore.shared.currentTrack?.id == track.id {
            PlayerCore.shared.stopAndClear()
        }
        try? FileManager.default.removeItem(at: track.url)
        tracks.removeAll { $0.id == track.id }
    }

    func resetIndex() {
        tracks.removeAll()
        try? FileManager.default.removeItem(at: Self.indexURL)
    }

    // MARK: - Metadata extraction (nonisolated)

    nonisolated private static func readMetadata(url: URL) async -> (
        title: String, artist: String, album: String, duration: Double, colors: [String]
    ) {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Неизвестный исполнитель"
        var album = ""
        var duration = 0.0
        var colors: [String] = []

        if let meta = try? await asset.load(.commonMetadata) {
            func first(_ id: AVMetadataIdentifier) -> String? {
                AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first?.stringValue
            }
            title = first(.commonIdentifierTitle) ?? title
            artist = first(.commonIdentifierArtist) ?? artist
            album = first(.commonIdentifierAlbumName) ?? album
            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = item.dataValue, let image = UIImage(data: data) {
                colors = artworkPalette(from: image)
            }
        }
        if let dur = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(dur)
        }
        return (title, artist, album, duration, colors)
    }

    // MARK: - Artwork color palette extraction

    nonisolated private static func artworkPalette(from image: UIImage) -> [String] {
        let size = 12
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
            let w = Int(s * s * 8) + 1
            buckets[bucket] += w
            hueSum[bucket] += Double(w) * h
            satSum[bucket] += Double(w) * s
            briSum[bucket] += Double(w) * v
        }

        let top = buckets.enumerated()
            .sorted { $0.element > $1.element }
            .prefix(3)
        var hexes: [String] = []
        for (idx, _) in top where buckets[idx] > 0 {
            let cnt = Double(buckets[idx])
            let hh = hueSum[idx] / cnt
            let ss = min(1, satSum[idx] / cnt + 0.15)
            let vv = max(0.35, min(0.8, briSum[idx] / cnt))
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

    // MARK: - Stable seed for deterministic palettes

    nonisolated private static func stableSeed(_ s: String) -> Int {
        var hash: UInt64 = 5381
        for b in s.utf8 { hash = (hash << 5) &+ hash &+ UInt64(b) }
        return Int(hash % 1000000)
    }
}
