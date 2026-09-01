import Foundation
import Observation

@MainActor
@Observable
final class AutoMixController {
    static let shared = AutoMixController()

    nonisolated struct Automation: Sendable {
        var outgoingVolume: Float
        var incomingVolume: Float
        var outgoingBassCutDB: Float
        var incomingBassGainDB: Float
        var outgoingHighCutDB: Float
        var incomingHighCutDB: Float
        var outgoingReverbMix: Float
        var incomingReverbMix: Float
    }

    private(set) var plan: TransitionDecision?
    private(set) var plannedTrackID: UUID?
    private(set) var isPreparing = false
    private var preparingTrackID: UUID?
    private var releaseTimer: Timer?
    private var releaseFrom: Float = 1
    private var releaseStart: Date?
    private let releaseDuration: TimeInterval = 6
    private let releaseTick: TimeInterval = 1.0 / 20.0

    private init() {}

    var badge: String? {
        guard let plan else { return nil }
        switch plan.scenario {
        case .fullBlend(let bars):
            var text = "AutoMix · \(bars) \(Self.barsWord(bars))"
            if plan.usesBeatLoop { text += " · Loop" }
            if let tempoShiftText { text += " · " + tempoShiftText }
            return text
        case .crossfade: return "Кроссфейд"
        case .gapRemoval: return "Без паузы"
        }
    }

    var tempoShiftText: String? {
        guard let plan, plan.isBeatMatched else { return nil }
        let percent = (Double(plan.tempoRate) - 1) * 100
        guard abs(percent) >= 0.1 else { return nil }
        return String(format: "темп %+.1f %%", percent)
    }

    var reason: String? { plan?.reason }
    var isBeatMatched: Bool { plan?.isBeatMatched ?? false }
    var incomingStartOffset: TimeInterval { plan?.incomingStart ?? 0 }

    func decision(for trackID: UUID) -> TransitionDecision? {
        plannedTrackID == trackID ? plan : nil
    }

    func prepare(outgoing: Track, outgoingDuration: TimeInterval, incoming: Track, mode: TransitionMode, crossfadeDuration: TimeInterval) {
        guard plannedTrackID != incoming.id, preparingTrackID != incoming.id else { return }
        guard outgoing.url.isFileURL, incoming.url.isFileURL, !outgoing.isStream, !incoming.isStream else { return }
        let target = Self.autoMixMode(from: mode)
        guard target != .off else { return }

        preparingTrackID = incoming.id
        isPreparing = true
        let outgoingID = outgoing.id
        let outgoingURL = outgoing.url
        let incomingID = incoming.id
        let incomingURL = incoming.url

        Task { [weak self] in
            let service = TrackAnalysisService.shared
            async let first = service.analysis(trackID: outgoingID, url: outgoingURL)
            async let second = service.analysis(trackID: incomingID, url: incomingURL)
            let (outgoingAnalysis, incomingAnalysis) = await (first, second)
            guard let self else { return }
            self.isPreparing = false
            self.preparingTrackID = nil
            guard PlayerCore.shared.currentTrack?.id == outgoingID else { return }
            self.plan = TransitionPlanner.plan(TransitionContext(
                outgoingDuration: outgoingDuration,
                outgoing: outgoingAnalysis,
                incoming: incomingAnalysis,
                mode: target,
                crossfadeDuration: crossfadeDuration,
                maxDuration: 30,
                sameGenre: nil
            ))
            self.plannedTrackID = incomingID
        }
    }

    func automation(progress: Double) -> Automation? {
        guard let plan else { return nil }
        let p = Float(min(1, max(0, progress)))
        let out = cos(p * Float.pi / 2)
        let input = sin(p * Float.pi / 2)

        switch plan.curve {
        case .dissolve:
            return Automation(outgoingVolume: out, incomingVolume: input, outgoingBassCutDB: -6 * p, incomingBassGainDB: -6 * (1 - p), outgoingHighCutDB: -12 * p, incomingHighCutDB: -8 * (1 - p), outgoingReverbMix: 32 * p, incomingReverbMix: 12 * (1 - p))
        case .cut:
            let fade = min(1, p / 0.25)
            return Automation(outgoingVolume: 1 - fade, incomingVolume: 1, outgoingBassCutDB: -18 * fade, incomingBassGainDB: 0, outgoingHighCutDB: -30 * fade, incomingHighCutDB: 0, outgoingReverbMix: 58 * fade, incomingReverbMix: 0)
        case .bassSwap:
            let handOver = min(1, p / 0.55)
            let received = min(1, max(0, (p - 0.35) / 0.45))
            let loopBoost: Float = plan.usesBeatLoop ? 1.25 : 1
            return Automation(
                outgoingVolume: out,
                incomingVolume: input,
                outgoingBassCutDB: -24 * handOver,
                incomingBassGainDB: -20 * (1 - received),
                outgoingHighCutDB: -28 * p,
                incomingHighCutDB: -16 * (1 - received),
                outgoingReverbMix: min(62, 46 * p * loopBoost),
                incomingReverbMix: 18 * (1 - p)
            )
        }
    }

    func promotedOffset(blend: TimeInterval) -> TimeInterval {
        guard let plan else { return max(0, blend) }
        let rate = plan.isBeatMatched ? Double(plan.tempoRate) : 1
        return max(0, plan.incomingStart + max(0, blend) * rate)
    }

    func finishTransition() {
        let matchedRate = (plan?.isBeatMatched ?? false) ? (plan?.tempoRate ?? 1) : 1
        plan = nil
        plannedTrackID = nil
        preparingTrackID = nil
        guard abs(matchedRate - 1) > 0.0005 else {
            stopRelease(); PlayerCore.shared.resetPlaybackRates(); return
        }
        releaseFrom = matchedRate
        releaseStart = Date()
        PlayerCore.shared.setOutgoingPlaybackRate(matchedRate)
        releaseTimer?.invalidate()
        let timer = Timer(timeInterval: releaseTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRelease() }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    func cancel() {
        plan = nil; plannedTrackID = nil; preparingTrackID = nil; isPreparing = false
        stopRelease()
    }

    private func tickRelease() {
        guard let start = releaseStart else { stopRelease(); return }
        let progress = min(1, max(0, -start.timeIntervalSinceNow / releaseDuration))
        let eased = Float(progress * progress * (3 - 2 * progress))
        let rate = releaseFrom + (1 - releaseFrom) * eased
        PlayerCore.shared.setOutgoingPlaybackRate(rate)
        PlayerCore.shared.nudgePlaybackAnchor(by: TimeStretchEngine.audioTimeDrift(rate: rate, elapsed: releaseTick))
        if progress >= 1 { stopRelease(); PlayerCore.shared.resetPlaybackRates() }
    }

    private func stopRelease() {
        releaseTimer?.invalidate(); releaseTimer = nil; releaseStart = nil; releaseFrom = 1
    }

    nonisolated static func autoMixMode(from mode: TransitionMode) -> AutoMixMode {
        switch mode {
        case .automix: return .automix
        case .crossfade: return .crossfade
        case .gapless: return .gapless
        case .off: return .off
        }
    }

    nonisolated private static func barsWord(_ bars: Int) -> String {
        let hundreds = bars % 100
        if hundreds >= 11 && hundreds <= 14 { return "тактов" }
        switch bars % 10 { case 1: return "такт"; case 2, 3, 4: return "такта"; default: return "тактов" }
    }
}
