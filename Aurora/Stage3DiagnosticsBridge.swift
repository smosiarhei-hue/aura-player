import Foundation
import MixDiagnostics
import MixModels
import MixPlanner
import PlaybackCoordinator

extension MixDiagnosticsStore {
    func textReport(coordinator: PlaybackCoordinator) async -> String {
        let state = await coordinator.snapshot()
        let engine = await coordinator.engineSnapshot()
        let active = state.activeDeck == .a ? engine.deckA : engine.deckB
        let plan = await MainActor.run { AutoMixV2AnalysisRuntime.shared.transitionPlan }
        let type = plan?.type.rawValue ?? "none"
        let bar: Double
        let progress: Double
        let activeFX: String
        let fallback: String
        if let plan, plan.tempoTargetBPM > 0, plan.bars > 0 {
            let elapsed = max(0, active.positionSeconds - plan.aOutStartSec)
            bar = EffectAutomation.bar(atSeconds: elapsed, bpm: plan.tempoTargetBPM)
            progress = min(1, max(0, bar / plan.bars))
            activeFX = plan.fx.compactMap { event in
                guard event.kind != .volume,
                      let value = EffectAutomation.value(for: event, atBar: bar),
                      bar <= event.endBar else { return nil }
                return "\(event.target.rawValue).\(event.kind.rawValue)=\(String(format: "%.2f", value))"
            }.joined(separator: ",")
            fallback = "none"
        } else {
            bar = 0; progress = 0; activeFX = "neutral"
            fallback = plan?.reason ?? state.lastQueueError ?? "none"
        }
        return ["Stage 4 effects executor", "phase=\(state.phase)",
                "deck=\(state.activeDeck.rawValue)",
                String(format: "position=%.3f", active.positionSeconds),
                "transition=\(state.isTransitioning)", "type=\(type)",
                String(format: "targetBPM=%.2f", plan?.tempoTargetBPM ?? 0),
                String(format: "rateA=%.5f rateB=%.5f", plan?.rateA ?? 1, plan?.rateB ?? 1),
                String(format: "fxBar=%.3f fxProgress=%.3f", bar, progress),
                "activeFX=\(activeFX.isEmpty ? "neutral" : activeFX)",
                "fallback=\(fallback)"].joined(separator: "\n")
    }
}
