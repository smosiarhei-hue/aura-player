// Path: Packages/AutoMixV2/Sources/TrackAnalysis/HarmonicKeyDetector.swift

import Foundation

public enum HarmonicKeyDetector {
    private static let major: [Float] = [6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88]
    private static let minor: [Float] = [6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17]
    private static let majorCamelot = ["8B","3B","10B","5B","12B","7B","2B","9B","4B","11B","6B","1B"]
    private static let minorCamelot = ["5A","12A","7A","2A","9A","4A","11A","6A","1A","8A","3A","10A"]

    public static func estimate(chroma: [Float]) -> (camelot: String?, confidence: Float) {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else { return (nil, 0) }
        let total = chroma.reduce(0, +)
        let normalized = chroma.map { $0 / max(total, 1e-9) }
        var candidates: [(score: Float, key: String)] = []
        for root in 0..<12 {
            let majorScore = (0..<12).reduce(Float(0)) { $0 + normalized[$1] * major[($1 - root + 12) % 12] }
            let minorScore = (0..<12).reduce(Float(0)) { $0 + normalized[$1] * minor[($1 - root + 12) % 12] }
            candidates.append((majorScore, majorCamelot[root]))
            candidates.append((minorScore, minorCamelot[root]))
        }
        candidates.sort { $0.score > $1.score }
        guard let first = candidates.first else { return (nil, 0) }
        let second = candidates.dropFirst().first?.score ?? 0
        let confidence = min(1, max(0, (first.score - second) / max(abs(first.score), 1e-6) * 5))
        return (confidence >= 0.15 ? first.key : nil, confidence)
    }
}
