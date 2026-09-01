#!/usr/bin/env python3
"""Wire AutoMixController into PlayerCore (AutoMix stage 4).

Runs after automix_v3.py and automix_timestretch.py, so the anchors below match
the already patched source. What it changes:

1. scheduleTransitionIfNeeded starts the lookahead analysis for local files and
   lets the planned decision override the cue point and blend length.
2. The incoming lane is scheduled from its planned entry point (after the
   intro, snapped to a bar) and at the rate that matches the outgoing BPM.
3. tickTransition drives volumes and the bass swap from the planned curve.
4. completeTransition promotes the real audio position and hands the tempo
   release ramp to the controller; cancelTransition resets the rates.
5. nudgePlaybackAnchor keeps the scrubber honest while a lane is stretched.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"


def patch(text, anchor, replacement, marker, label):
    if marker in text:
        print("skip (already applied): " + label)
        return text
    if text.count(anchor) != 1:
        raise RuntimeError(label + ": required source anchor was not found exactly once")
    print("applied: " + label)
    return text.replace(anchor, replacement, 1)


# 1. Lookahead + planned cue point ------------------------------------------
PLAN_ANCHOR = r'''        // When AutoMixEngine has actually listened to the audio, its cue point
        // and blend length replace the metadata guess.
        if transitionMode == .automix,
           let analysed = autoMixPlan,
           autoMixPreparedTrackId == nextTrack.id {
            plan.blendDuration = analysed.duration
            plan.cueTime = max(0, totalDur - analysed.leadTime)
            plan.style = analysed.style
        }
'''

PLAN_REPLACEMENT = r'''        // When AutoMixEngine has actually listened to the audio, its cue point
        // and blend length replace the metadata guess.
        if transitionMode == .automix,
           let analysed = autoMixPlan,
           autoMixPreparedTrackId == nextTrack.id {
            plan.blendDuration = analysed.duration
            plan.cueTime = max(0, totalDur - analysed.leadTime)
            plan.style = analysed.style
        }

        // Local files go through the offline AutoMix pipeline: beat grid,
        // Camelot key and structure of both sides of the junction. Its decision
        // wins because it is the only one that listened to the actual audio.
        if !isUsingStreamPlayer, !nextTrack.isStream, !current.isStream {
            AutoMixController.shared.prepare(
                outgoing: current,
                outgoingDuration: totalDur,
                incoming: nextTrack,
                mode: transitionMode,
                crossfadeDuration: crossfadeDuration
            )
            if let decision = AutoMixController.shared.decision(for: nextTrack.id) {
                plan.blendDuration = decision.duration
                plan.cueTime = decision.cueTime
            }
        }
'''

# 2. Beat-matched entry of the incoming lane --------------------------------
ENTRY_ANCHOR = r'''        Task {
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile

                let frameCount = AVAudioFrameCount(nextFile.length)
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: 0, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
'''

ENTRY_REPLACEMENT = r'''        let decision = AutoMixController.shared.decision(for: nextTrack.id)

        Task {
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile

                // Enter where the planner said: past the quiet intro, on a bar
                // start, running at the tempo of the outgoing track.
                let incomingRate: Float = (decision?.isBeatMatched ?? false) ? (decision?.tempoRate ?? 1) : 1
                self.setIncomingPlaybackRate(incomingRate)

                let incomingSampleRate = nextFile.processingFormat.sampleRate
                let skipSeconds = max(0, decision?.incomingStart ?? 0)
                let requestedFrame = AVAudioFramePosition(skipSeconds * incomingSampleRate)
                let startFrame = max(0, min(requestedFrame, max(0, nextFile.length - 1)))
                let frameCount = AVAudioFrameCount(max(0, nextFile.length - startFrame))
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: startFrame, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
'''

# 3. Planned volume / bass-swap automation ---------------------------------
AUTOMATION_ANCHOR = r'''        let style = AutoMixDJEngine.shared.activeStyle
        let (outVol, inVol, outBassCut, inBassGain) = AutoMixDJEngine.shared.computeVolumesAndEQ(progress: p, style: style)
'''

AUTOMATION_REPLACEMENT = r'''        let style = AutoMixDJEngine.shared.activeStyle
        var (outVol, inVol, outBassCut, inBassGain) = AutoMixDJEngine.shared.computeVolumesAndEQ(progress: p, style: style)

        // A planned local blend drives its own curve: equal power for a
        // crossfade, a real bass swap for a beat-matched blend.
        if let automation = AutoMixController.shared.automation(progress: p) {
            outVol = automation.outgoingVolume
            inVol = automation.incomingVolume
            outBassCut = automation.outgoingBassCutDB
            inBassGain = automation.incomingBassGainDB
        }
'''

# 4a. Promote the true audio position --------------------------------------
PROMOTE_ANCHOR = r'''            promoted = max(0, transitionDuration)
'''

PROMOTE_REPLACEMENT = r'''            // The lane started at its planned entry point and may have run
            // stretched, so the elapsed wall clock is not the file position.
            promoted = AutoMixController.shared.promotedOffset(blend: max(0, transitionDuration))
'''

# 4b. Hand over the tempo release ------------------------------------------
RELEASE_ANCHOR = r'''        incomingTrack = nil
        prebufferedTrackId = nil
        clearAutoMixPreparation()
'''

RELEASE_REPLACEMENT = r'''        // The promoted lane still carries the matched tempo: ease it back to
        // the track's own speed over the next seconds instead of snapping.
        AutoMixController.shared.finishTransition()

        incomingTrack = nil
        prebufferedTrackId = nil
        clearAutoMixPreparation()
'''

# 4c. Cancelling a blend resets the rates ----------------------------------
CANCEL_ANCHOR = r'''        incomingAudioFile = nil
        isTransitioning = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        applyEQ()
'''

CANCEL_REPLACEMENT = r'''        incomingAudioFile = nil
        isTransitioning = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixController.shared.cancel()
        resetPlaybackRates()
        applyEQ()
'''

# 5. Scrubber anchor correction while stretched ----------------------------
ANCHOR_API_ANCHOR = r'''    private func liveProgress() -> Double {
'''

ANCHOR_API_REPLACEMENT = r'''    /// Keeps the scrubber honest while a lane is time-stretched: at rate r the
    /// lane covers r seconds of audio per second of wall clock, and progress is
    /// measured against the wall clock.
    func nudgePlaybackAnchor(by seconds: Double) {
        guard seconds.isFinite, abs(seconds) > 0.0001 else { return }
        anchorOffset = max(0, anchorOffset + seconds)
        pausedProgress = max(0, pausedProgress + seconds)
    }

    private func liveProgress() -> Double {
'''


def main():
    if not PLAYER.exists():
        raise RuntimeError("missing source file: " + str(PLAYER))

    text = PLAYER.read_text(encoding="utf-8")
    text = patch(text, PLAN_ANCHOR, PLAN_REPLACEMENT,
                 "AutoMixController.shared.prepare(", "lookahead and planned cue point")
    text = patch(text, ENTRY_ANCHOR, ENTRY_REPLACEMENT,
                 "let incomingRate: Float", "beat matched lane entry")
    text = patch(text, AUTOMATION_ANCHOR, AUTOMATION_REPLACEMENT,
                 "AutoMixController.shared.automation(", "planned blend automation")
    text = patch(text, PROMOTE_ANCHOR, PROMOTE_REPLACEMENT,
                 "AutoMixController.shared.promotedOffset(", "promoted audio position")
    text = patch(text, RELEASE_ANCHOR, RELEASE_REPLACEMENT,
                 "AutoMixController.shared.finishTransition(", "tempo release handover")
    text = patch(text, CANCEL_ANCHOR, CANCEL_REPLACEMENT,
                 "AutoMixController.shared.cancel()", "cancel resets rates")
    text = patch(text, ANCHOR_API_ANCHOR, ANCHOR_API_REPLACEMENT,
                 "func nudgePlaybackAnchor(", "scrubber anchor correction")
    PLAYER.write_text(text, encoding="utf-8")
    print("AutoMix stage 4 wired into PlayerCore.")


if __name__ == "__main__":
    sys.exit(main())
