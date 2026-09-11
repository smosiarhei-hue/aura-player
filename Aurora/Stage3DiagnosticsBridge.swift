import Foundation
import MixDiagnostics
import MixModels
import MixPlanner
import PlaybackCoordinator

extension MixDiagnosticsStore {
    func textReport(coordinator: PlaybackCoordinator) async -> String {
        let state = await coordinator.snapshot()
        let engine = await coordinator.engineSnapshot()
        let readiness = await coordinator.transitionReadiness
        let readinessReason = await coordinator.transitionReason
        let active = state.activeDeck == .a ? engine.deckA : engine.deckB
        let plan = await MainActor.run { () -> MixModels.TransitionPlan? in
            guard let currentIndex = state.currentIndex,
                  let nextIndex = state.preparedIndex,
                  state.queue.indices.contains(currentIndex),
                  state.queue.indices.contains(nextIndex) else { return nil }
            return AutoMixV2AnalysisRuntime.shared.plan(for: state.queue[currentIndex], nextID: state.queue[nextIndex])
        }
        let analysisStatus = await MainActor.run { AutoMixV2AnalysisRuntime.shared.pipelineStatus }
        let analysisError = await MainActor.run { AutoMixV2AnalysisRuntime.shared.lastError }
        let type = plan?.type.rawValue ?? (readiness == .fallback ? "fallbackCrossfade" : "none")
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
            bar = 0; progress = 0; activeFX = readiness == .fallback ? "crossfade" : "neutral"
            fallback = analysisError ?? plan?.reason ?? readinessReason
        }
        return ["Stage 4 effects executor", "phase=\(state.phase)",
                "deck=\(state.activeDeck.rawValue)",
                String(format: "position=%.3f", active.positionSeconds),
                "transition=\(state.isTransitioning)", "type=\(type)",
                "readiness=\(readiness.rawValue)",
                "readinessReason=\(readinessReason)",
                "analysis=\(analysisStatus)",
                String(format: "targetBPM=%.2f", plan?.tempoTargetBPM ?? 0),
                String(format: "rateA=%.5f rateB=%.5f", plan?.rateA ?? 1, plan?.rateB ?? 1),
                String(format: "fxBar=%.3f fxProgress=%.3f", bar, progress),
                "activeFX=\(activeFX.isEmpty ? "neutral" : activeFX)",
                "fallback=\(fallback)"].joined(separator: "\n")
    }
}
