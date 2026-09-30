import SwiftUI
import UniformTypeIdentifiers

// MARK: - Transition Mode

enum TransitionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case gapless = "Gapless (Без пауз)"
    case crossfade = "Кроссфейд"
    case off = "Выключено"
    case automix = "AutoMix (Отключено)"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .gapless:
            return "Мгновенное переключение следующего трека без пауз в оригинальном чистом качестве."
        case .crossfade:
            return "Классическое плавное наложение звука по фиксированному времени."
        case .off:
            return "Стандартное раздельное воспроизведение треков."
        case .automix:
            return "Отключено для сохранения оригинального звучания."
        }
    }
}

// MARK: - AutoMix DJ Engine (AI & DSP Transition Executor)

extension Notification.Name {
    static let didTriggerAutoMixDrop = Notification.Name("didTriggerAutoMixDrop")
    static let didCompleteAutoMixTransition = Notification.Name("didCompleteAutoMixTransition")
}

@Observable
@MainActor
final class AutoMixDJEngine {
    static let shared = AutoMixDJEngine()

    var isTransitionActive: Bool = false
    var transitionProgress: Double = 0.0
    var activeStrategyName: String = "GAPLESS"
    var statusBadge: String? = nil
    var currentBPM: Double = 0
    var isDropTriggered: Bool = false
    var dropProgress: Double = 0.50
    var isPostMixActive: Bool = false

    private init() {}

    func notifyDrop(targetTrack: Track?) {
        // AutoMix Drop Hard Cut completely disabled to preserve audio continuity
    }

    func resetDrop() {
        isDropTriggered = false
        isPostMixActive = false
    }

    func computeVolumesAndEQ(
        progress: Double,
        strategy: String = "GAPLESS"
    ) -> (outgoingVol: Float, incomingVol: Float, outgoingBassCutDB: Float, incomingBassGainDB: Float, filterCutoff: Float) {
        let p = max(0.0, min(1.0, progress))
        // Pure Equal-Power Cosine Crossfade for local files (zero bass cut, zero filtering)
        let outVol = Float(cos(p * (.pi / 2)))
        let inVol = Float(sin(p * (.pi / 2)))
        return (outVol, inVol, 0.0, 0.0, 1.0)
    }
}

// MARK: - Track Model

struct Track: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var fileName: String
    var relativePath: String = ""
    var title: String
    var artist: String
    var album: String
    var duration: Double = 0
    var artworkSeed: Int = 0
    var colorsHex: [String] = []
    var hasEmbeddedArtwork: Bool = false
    var isFavorite: Bool = false
    var addedAt: Date = Date()
    var isStream: Bool = false
    var streamUrlString: String? = nil
    var coverURL: String? = nil
    var lyricsText: String? = nil

    var url: URL {
        if isStream, let str = streamUrlString, let u = URL(string: str) {
            return u
        }
        if !relativePath.isEmpty {
            return documentsDirectoryURL().appendingPathComponent(relativePath)
        }
        return documentsDirectoryURL().appendingPathComponent(fileName)
    }

    var palette: [Color] {
        let parsed = colorsHex.compactMap { Color(hex: $0) }
        return parsed.isEmpty ? Palette.seeded(artworkSeed).colors : parsed
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id || (lhs.fileName == rhs.fileName && !lhs.fileName.isEmpty)
    }
}

// MARK: - Playlist Model

struct Playlist: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var trackIds: [UUID] = []
    var coverGradient: [String] = ["#FF455B", "#9333EA"]
    var coverURL: String? = nil
    var cachedTracks: [Track] = []

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, trackIds, coverGradient, coverURL, cachedTracks
    }

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        trackIds: [UUID] = [],
        coverGradient: [String] = ["#FF455B", "#9333EA"],
        coverURL: String? = nil,
        cachedTracks: [Track] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.trackIds = trackIds
        self.coverGradient = coverGradient
        self.coverURL = coverURL
        self.cachedTracks = cachedTracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.trackIds = try container.decodeIfPresent([UUID].self, forKey: .trackIds) ?? []
        self.coverGradient = try container.decodeIfPresent([String].self, forKey: .coverGradient) ?? ["#FF455B", "#9333EA"]
        self.coverURL = try container.decodeIfPresent(String.self, forKey: .coverURL)
        self.cachedTracks = try container.decodeIfPresent([Track].self, forKey: .cachedTracks) ?? []
    }
}

// MARK: - Repeat / Shuffle

enum RepeatMode: Int, Codable, CaseIterable, Sendable {
    case off = 0, all = 1, one = 2

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var title: String {
        switch self {
        case .off: return "Выкл"
        case .all: return "Все"
        case .one: return "Один"
        }
    }
}

// MARK: - EQ Presets

struct EQPreset: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let gains: [Float]
}

enum EQPresets {
    static let flat = EQPreset(name: "По умолчанию", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    static let classical = EQPreset(name: "Классическая музыка", gains: [6, 5, 4, 3, 2, 1, 0, -1, -2, -3])
    static let club = EQPreset(name: "Клубная музыка", gains: [8, 7, 6, 4, 2, 2, 3, 5, 6, 6])
    static let dance = EQPreset(name: "Танцевальная музыка", gains: [9, 8, 7, 5, 3, 0, 2, 5, 7, 8])
    static let bassBoost = EQPreset(name: "Усиление НЧ", gains: [14, 12, 10, 7, 4, 1, 0, 0, 0, 0])
    static let bassTrebleBoost = EQPreset(name: "Усиление НЧ и ВЧ", gains: [12, 10, 8, 5, 2, 0, 3, 6, 9, 11])

    static let all: [EQPreset] = [
        flat,
        classical,
        club,
        dance,
        bassBoost,
        bassTrebleBoost
    ]
}

// MARK: - Palette

struct Palette {
    let colors: [Color]

    static func seeded(_ seed: Int) -> Palette {
        var gen = SeededGenerator(seed: UInt64(truncatingIfNeeded: Int64(seed &+ 7331)))
        let base = Double.random(in: 0...1, using: &gen)
        var result: [Color] = []
        let offsets: [Double] = [0.0, 0.08, -0.12, 0.45, -0.28]
        for offset in offsets {
            let hue = (base + offset).truncatingRemainder(dividingBy: 1.0)
            let sat = Double.random(in: 0.65...0.90, using: &gen)
            let bri = Double.random(in: 0.50...0.80, using: &gen)
            result.append(Color(hue: hue < 0 ? hue + 1.0 : hue, saturation: sat, brightness: bri))
        }
        return Palette(colors: result)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Global Directory Helpers

nonisolated func documentsDirectoryURL() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

nonisolated func musicDirectoryURL() -> URL {
    let dir = documentsDirectoryURL().appendingPathComponent("Music", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

nonisolated func artworkCacheDirectoryURL() -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let dir = caches.appendingPathComponent("ArtworkCache", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Color Hex Conversion

extension Color {
    init?(hex: String) {
        var value: String = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        guard let comps = UIColor(self).cgColor.components, comps.count >= 3 else { return "#888888" }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
