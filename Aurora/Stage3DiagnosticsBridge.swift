import MixDiagnostics
import MixModels
import PlaybackCoordinator

extension MixDiagnosticsStore {
    func textReport(coordinator: PlaybackCoordinator) async -> String {
        let state = await coordinator.snapshot()
        let engine = await coordinator.engineSnapshot()
        let active = state.activeDeck == .a ? engine.deckA : engine.deckB
        let plan = await MainActor.run { AutoMixV2AnalysisRuntime.shared.transitionPlan }
        let type = plan?.type.rawValue ?? "none"
        return ["Stage 3 beatmatch executor", "phase=\(state.phase)",
                "deck=\(state.activeDeck.rawValue)",
                String(format: "position=%.3f", active.positionSeconds),
                "transition=\(state.isTransitioning)", "type=\(type)",
                String(format: "targetBPM=%.2f", plan?.tempoTargetBPM ?? 0),
                String(format: "rateA=%.5f rateB=%.5f", plan?.rateA ?? 1, plan?.rateB ?? 1)].joined(separator: "\n")
    }
}
