// Path: Sonivo/DJAutoMixEngine/TrackAnalyzer.swift
import Foundation

public protocol DJTrackAnalyzer: Sendable {
    func analyze(_ url: URL) async throws -> DJTrackAnalysis
}

public actor DJTrackAnalysisCache {
    public static let shared = DJTrackAnalysisCache()

    private var memoryCache: [String: DJTrackAnalysis] = [:]

    public init() {}

    public func get(key: String) -> DJTrackAnalysis? {
        memoryCache[key]
    }

    public func set(key: String, analysis: DJTrackAnalysis) {
        memoryCache[key] = analysis
    }

    public func clear() {
        memoryCache.removeAll()
    }
}

nonisolated public enum TrackAnalyzerError: LocalizedError, Sendable {
    case fileNotFound
    case featureExtractionFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Файл трека не найден"
        case .featureExtractionFailed:
            return "Не удалось извлечь спектральные характеристики трека"
        case .decodingFailed:
            return "Не удалось декодировать аудиодорожку"
        }
    }
}

public final class AudioTrackAnalyzer: DJTrackAnalyzer, @unchecked Sendable {
    public init() {}

    public func analyze(_ url: URL) async throws -> DJTrackAnalysis {
        let cacheKey = url.absoluteString
        if let cached = await DJTrackAnalysisCache.shared.get(key: cacheKey) {
            return cached
        }

        // 1. Извлечение признаков с помощью vDSP
        guard let features = await AutoMixDSP.features(for: url) else {
            throw TrackAnalyzerError.featureExtractionFailed
        }

        // 2. Детектирование тональности
        let key = KeyDetector.detect(chroma: features.chroma)
        let camelotPos = CamelotPosition(key: key)
        let camelotKey = CamelotKey(number: camelotPos.number, letter: camelotPos.isMajor ? .b : .a)

        // 3. Детектирование темпа и сетки долей
        let beatResult = BeatAnalyzer.analyze(features: features)
        let bpm = beatResult.bpm > 30 ? beatResult.bpm : 124.0
        let beatGrid = beatResult.beatGrid.isEmpty
            ? stride(from: 0.0, through: features.duration, by: 60.0 / bpm).map { $0 }
            : beatResult.beatGrid

        // 4. Детектирование структуры и пауз
        let structureResult = StructureAnalyzer.analyze(features: features, downbeats: beatResult.downbeats)

        let leadIn = structureResult.silenceRegions.first(where: { $0.start < 1.0 })?.duration ?? 0.15
        let trailing = structureResult.silenceRegions.last(where: { $0.end >= features.duration - 2.0 })?.duration ?? 0.35

        var segments: [StructureSegment] = []
        for section in structureResult.sections {
            let energy = section.energy
            let isVocal = section.type == .chorus || section.type == .verse
            segments.append(StructureSegment(range: section.start..<section.end, energy: energy, isVocal: isVocal))
        }

        if segments.isEmpty {
            let introEnd = min(15.0, features.duration * 0.15)
            let outroStart = max(introEnd, features.duration * 0.85)
            segments = [
                StructureSegment(range: 0.0..<introEnd, energy: 0.4, isVocal: false),
                StructureSegment(range: introEnd..<outroStart, energy: 0.8, isVocal: true),
                StructureSegment(range: outroStart..<features.duration, energy: 0.45, isVocal: false)
            ]
        }

        let combinedConfidence = Double(min(1.0, max(0.2, (beatResult.confidence + Float(key.confidence)) / 2.0)))

        let analysis = DJTrackAnalysis(
            trackID: UUID(),
            bpm: bpm,
            key: camelotKey,
            beatGrid: beatGrid,
            structure: segments,
            leadInSilence: leadIn,
            trailingSilence: trailing,
            confidence: combinedConfidence
        )

        await DJTrackAnalysisCache.shared.set(key: cacheKey, analysis: analysis)
        return analysis
    }
}

public actor MockTrackAnalyzer: DJTrackAnalyzer {
    private var stubs: [URL: DJTrackAnalysis] = [:]
    private var defaultStub: DJTrackAnalysis?

    public init(defaultStub: DJTrackAnalysis? = nil) {
        self.defaultStub = defaultStub
    }

    public func stub(url: URL, analysis: DJTrackAnalysis) {
        stubs[url] = analysis
    }

    public func setDefault(_ analysis: DJTrackAnalysis) {
        defaultStub = analysis
    }

    public func analyze(_ url: URL) async throws -> DJTrackAnalysis {
        let cacheKey = url.absoluteString
        if let cached = await DJTrackAnalysisCache.shared.get(key: cacheKey) {
            return cached
        }

        let stub = stubs[url] ?? defaultStub
        if let stub {
            await DJTrackAnalysisCache.shared.set(key: cacheKey, analysis: stub)
            return stub
        }

        // Базовый mock для сквозного тестирования пайплайна
        let fallback = DJTrackAnalysis(
            trackID: UUID(),
            bpm: 124.0,
            key: CamelotKey(number: 8, letter: .a),
            beatGrid: stride(from: 0.0, through: 180.0, by: 60.0 / 124.0).map { $0 },
            structure: [
                StructureSegment(range: 0.0..<15.0, energy: 0.4, isVocal: false),
                StructureSegment(range: 15.0..<165.0, energy: 0.85, isVocal: true),
                StructureSegment(range: 165.0..<180.0, energy: 0.5, isVocal: false)
            ],
            leadInSilence: 0.20,
            trailingSilence: 0.50,
            confidence: 0.90
        )
        await DJTrackAnalysisCache.shared.set(key: cacheKey, analysis: fallback)
        return fallback
    }
}
