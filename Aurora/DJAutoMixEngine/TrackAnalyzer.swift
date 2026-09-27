// Path: Aurora/DJAutoMixEngine/TrackAnalyzer.swift
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
