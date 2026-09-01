import Foundation
import Observation

// MARK: - AutoMix orchestration
//
// Sits on top of PlayerCore and turns the offline analysis into an actual
// transition:
//
//   1. Queue lookahead - analyses the next track (and the current one) well
//      before the junction, off the main actor, result cached on disk.
//   2. Beat grid sync - hands PlayerCore the entry point of the incoming track
//      (after its intro, snapped to a bar) and the rate that matches its BPM
//      to the outgoing track.
//   3. Volume and EQ automation for every frame of the blend, reusing the
//      existing 10-band EQ for the bass swap instead of adding another one.
//   4. Tempo release - after the swap the stretched lane eases back to its own
//      speed over a few seconds instead of snapping, with the scrubber anchor
//      corrected for the wall-clock drift a rate != 1 introduces.
//
// Only local files go through here: beat matching needs AVAudioEngine, so
// streamed tracks keep the dual-AVPlayer path in AutoMixEngine.swift.

@MainActor
@Observable
final class AutoMixController {
    static let shared = AutoMixController()

    nonisolated struct Automation: Sendable {
        var outgoingVolume: Float
        var incomingVolume: Float
        var outgoingBassCutDB: Float
        var incomingBassGainDB: Float
    }

    /// Decision for the upcoming junction, nil until the analysis is ready.
    private(set) var plan: TransitionDecision?
    private(set) var plannedTrackID: UUID?
    private(set) var isPreparing = false

    private var preparingTrackID: UUID?

    // Tempo release ramp state.
    private var releaseTimer: Timer?
    private var releaseFrom: Float = 1
    private var releaseStart: Date?
    private let releaseDuration: TimeInterval = 6
    private let releaseTick: TimeInterval = 1.0 / 20.0

    private init() {}

    // MARK: - Read-only surface for the UI

    /// Short label for the player toast, the queue and Settings.
    var badge: String? {
        guard let plan else { return nil }
        switch plan.scenario {
        case .fullBlend(let bars):
            var text = "AutoMix · " + String(bars) + " " + Self.barsWord(bars)
            if let tempoShiftText {
                text += " · " + tempoShiftText
            }
            return text
        case .crossfade:
            return "Кроссфейд"
        case .gapRemoval:
            return "Без паузы"
        }
    }

    /// Tempo correction applied to the incoming lane, e.g. "темп +2.4 %".
    var tempoShiftText: String? {
        guard let plan, plan.isBeatMatched else { return nil }
        let percent = (Double(plan.tempoRate) - 1) * 100
        guard abs(percent) >= 0.1 else { return nil }
        return String(format: "темп %+.1f %%", percent)
    }

    /// Why the planner chose this scenario. Useful in Settings and for debugging.
    var reason: String? { plan?.reason }

    var isBeatMatched: Bool { plan?.isBeatMatched ?? false }

    /// Where the incoming lane was told to start playing.
    var incomingStartOffset: TimeInterval { plan?.incomingStart ?? 0 }

    func decision(for trackID: UUID) -> TransitionDecision? {
        guard plannedTrackID == trackID else { return nil }
        return plan
    }

    // MARK: - Lookahead

    /// Analyse both sides of the junction and build the plan. Cheap to call
    /// repeatedly: it returns immediately once a plan exists or work is running.
    func prepare(
        outgoing: Track,
        outgoingDuration: TimeInterval,
        incoming: Track,
        mode: TransitionMode,
        crossfadeDuration: TimeInterval
    ) {
        guard plannedTrackID != incoming.id, preparingTrackID != incoming.id else { return }
        guard outgoing.url.isFileURL, incoming.url.isFileURL else { return }
        guard !outgoing.isStream, !incoming.isStream else { return }

        let target = Self.autoMixMode(from: mode)
        guard target != .off else { return }

        preparingTrackID = incoming.id
        isPreparing = true

        let maxDuration = AutoMixDJEngine.shared.maxTransitionDuration
        let outgoingID = outgoing.id
        let outgoingURL = outgoing.url
        let incomingID = incoming.id
        let incomingURL = incoming.url

        Task { [weak self] in
            let service = TrackAnalysisService.shared
            let outgoingAnalysis = await service.analysis(trackID: outgoingID, url: outgoingURL)
            let incomingAnalysis = await service.analysis(trackID: incomingID, url: incomingURL)

            guard let self else { return }
            self.isPreparing = false
            self.preparingTrackID = nil

            // The user may have skipped while we were listening to the file.
            guard PlayerCore.shared.currentTrack?.id == outgoingID else { return }

            let context = TransitionContext(
                outgoingDuration: outgoingDuration,
                outgoing: outgoingAnalysis,
                incoming: incomingAnalysis,
                mode: target,
                crossfadeDuration: crossfadeDuration,
                maxDuration: maxDuration,
                sameGenre: nil
            )

            self.plan = TransitionPlanner.plan(context)
            self.plannedTrackID = incomingID
        }
    }

    // MARK: - Blend automation

    /// Volume and bass-swap values for the current point of the blend, or nil
    /// when there is no planned transition and the legacy curve should be used.
    func automation(progress: Double) -> Automation? {
        guard let plan else { return nil }
        let p = Float(min(1, max(0, progress)))

        switch plan.curve {
        case .dissolve:
            // Equal power, so the perceived loudness stays flat.
            return Automation(
                outgoingVolume: cos(p * Float.pi / 2),
                incomingVolume: sin(p * Float.pi / 2),
                outgoingBassCutDB: 0,
                incomingBassGainDB: 0
            )

        case .cut:
            // Gap removal: no blend, just do not slam the door.
            let fade = min(1, p / 0.25)
            return Automation(
                outgoingVolume: 1 - fade,
                incomingVolume: 1,
                outgoingBassCutDB: 0,
                incomingBassGainDB: 0
            )

        case .bassSwap:
            // Two kick drums stacking is what makes amateur mixes muddy, so the
            // low end belongs to exactly one lane at a time: A gives it up over
            // the first half, B receives it over the second.
            let outVolume = cos(p * Float.pi / 2)
            let inVolume = sin(p * Float.pi / 2)
            let handOver = min(1, p / 0.55)
            let received = min(1, max(0, (p - 0.35) / 0.45))
            return Automation(
                outgoingVolume: outVolume,
                incomingVolume: inVolume,
                outgoingBassCutDB: -18 * handOver,
                incomingBassGainDB: -18 * (1 - received)
            )
        }
    }

    /// Position to promote the incoming lane to once it becomes active. It has
    /// been playing since `incomingStart`, and a stretched lane consumed the
    /// file faster or slower than the wall clock.
    func promotedOffset(blend: TimeInterval) -> TimeInterval {
        guard let plan else { return max(0, blend) }
        let rate = plan.isBeatMatched ? Double(plan.tempoRate) : 1
        return max(0, plan.incomingStart + max(0, blend) * rate)
    }

    // MARK: - Tempo release

    /// Called right after the lanes are swapped. Eases the matched tempo back to
    /// the track's own speed instead of snapping it.
    func finishTransition() {
        let matchedRate = (plan?.isBeatMatched ?? false) ? (plan?.tempoRate ?? 1) : 1
        plan = nil
        plannedTrackID = nil
        preparingTrackID = nil

        guard abs(matchedRate - 1) > 0.0005 else {
            stopRelease()
            PlayerCore.shared.resetPlaybackRates()
            return
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

    /// Manual skip, seek or a cancelled blend: drop everything.
    func cancel() {
        plan = nil
        plannedTrackID = nil
        preparingTrackID = nil
        stopRelease()
    }

    private func tickRelease() {
        guard let start = releaseStart else {
            stopRelease()
            return
        }

        let elapsed = -start.timeIntervalSinceNow
        let progress = min(1, max(0, elapsed / releaseDuration))
        let eased = Float(progress * progress * (3 - 2 * progress))
        let rate = releaseFrom + (1 - releaseFrom) * eased

        PlayerCore.shared.setOutgoingPlaybackRate(rate)

        // A lane running at rate r covers r seconds of audio per second of wall
        // clock, so the scrubber anchor has to follow or the timeline drifts.
        PlayerCore.shared.nudgePlaybackAnchor(
            by: TimeStretchEngine.audioTimeDrift(rate: rate, elapsed: releaseTick)
        )

        if progress >= 1 {
            stopRelease()
            PlayerCore.shared.resetPlaybackRates()
        }
    }

    private func stopRelease() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        releaseStart = nil
        releaseFrom = 1
    }

    // MARK: - Settings mapping

    /// Maps the player setting onto the planner mode.
    ///
    /// This used to switch over `mode.rawValue`, which is wrong: TransitionMode
    /// raw values are localised display strings ("Кроссфейд", "Выключено"), so
    /// everything except AutoMix fell through to the default and got beat
    /// matched even when the user had asked for a plain crossfade or no
    /// transition at all.
    nonisolated static func autoMixMode(from mode: TransitionMode) -> AutoMixMode {
        switch mode {
        case .automix:
            return .automix
        case .crossfade:
            return .crossfade
        case .gapless:
            return .gapless
        case .off:
            return .off
        }
    }

    /// 1 такт / 2 такта / 8 тактов.
    nonisolated private static func barsWord(_ bars: Int) -> String {
        let hundreds = bars % 100
        if hundreds >= 11 && hundreds <= 14 { return "тактов" }
        switch bars % 10 {
        case 1:
            return "такт"
        case 2, 3, 4:
            return "такта"
        default:
            return "тактов"
        }
    }
}
