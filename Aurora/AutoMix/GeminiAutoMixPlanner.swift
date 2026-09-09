import Foundation

// MARK: - Legacy transition data compatibility
// This file intentionally contains no Gemini client, API key, prompt, network
// request or server-side planning. The old player can only request a local,
// deterministic fallback while AutoMix V2 replaces it stage by stage.

nonisolated struct TransitionAction: Codable, Sendable {
    let time: Double
    let target: String
    let parameter: String
    let value: Double
    let duration: Double
}

nonisolated struct TransitionEffects: Codable, Sendable {
    var reverbPreset: String = "plate"

    static let reverbPresets = [
        "smallRoom", "mediumRoom", "largeRoom", "mediumHall", "largeHall",
        "plate", "mediumChamber", "largeChamber", "cathedral", "largeRoom2",
        "mediumHall2", "mediumHall3", "largeHall2"
    ]

    var resolvedReverbPreset: String {
        Self.reverbPresets.contains(reverbPreset) ? reverbPreset : "plate"
    }
}

nonisolated struct TransitionDecisionInfo: Codable, Sendable {
    let transitionType: String
    let confidence: Double
    let reason: String
}

nonisolated struct TransitionSourceTrackInfo: Codable, Sendable {
    let transitionStart: Double
    let transitionEnd: Double
    var duration: Double { max(0.5, transitionEnd - transitionStart) }
}

nonisolated struct TransitionTargetTrackInfo: Codable, Sendable {
    let startPosition: Double
}

nonisolated struct TransitionTempoInfo: Codable, Sendable {
    let targetBPM: Double
    let sourcePlaybackRate: Double
    let targetPlaybackRate: Double
}

nonisolated struct TransitionFallbackInfo: Codable, Sendable {
    let type: String
}

nonisolated struct TransitionPlan: Codable, Sendable {
    let decision: TransitionDecisionInfo
    let sourceTrack: TransitionSourceTrackInfo
    let targetTrack: TransitionTargetTrackInfo
    let tempo: TransitionTempoInfo
    let actions: [TransitionAction]
    let fallback: TransitionFallbackInfo
    var effects: TransitionEffects = TransitionEffects()

    var strategy: TransitionStrategy {
        TransitionStrategy(rawValue: decision.transitionType) ?? .BASS_SWAP
    }

    var leadTime: Double { sourceTrack.duration }
    var cueTime: Double { sourceTrack.transitionStart }
}

actor LocalLegacyTransitionPlanner {
    static let shared = LocalLegacyTransitionPlanner()
    nonisolated(unsafe) static var lastPlanUsedGemini = false

    private init() {}

    func planTransition(
        sourceTrack: Track,
        sourceAnalysis: TrackAnalysis,
        targetTrack: Track,
        targetAnalysis: TrackAnalysis,
        currentPosition: Double
    ) async -> TransitionPlan {
        _ = currentPosition
        return TransitionPlanner.planLocalFallback(
            sourceTrackID: sourceTrack.id,
            sourceAnalysis: sourceAnalysis,
            targetTrackID: targetTrack.id,
            targetAnalysis: targetAnalysis
        )
    }
}

// Temporary source-compatibility name for the legacy PlayerCore. It resolves
// to the local planner above and cannot contact Gemini or any other AI service.
typealias GeminiAutoMixPlanner = LocalLegacyTransitionPlanner
