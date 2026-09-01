#!/usr/bin/env python3
"""Wire the automatic planner, beat loop, filters and reverb into PlayerCore."""
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"

def patch(text, anchor, replacement, marker, label):
    if marker in text: return text
    if text.count(anchor) != 1: raise RuntimeError(label + ": anchor not found exactly once")
    return text.replace(anchor, replacement, 1)

PLAN = r'''        // When AutoMixEngine has actually listened to the audio, its cue point
        // and blend length replace the metadata guess.
        if transitionMode == .automix,
           let analysed = autoMixPlan,
           autoMixPreparedTrackId == nextTrack.id {
            plan.blendDuration = analysed.duration
            plan.cueTime = max(0, totalDur - analysed.leadTime)
            plan.style = analysed.style
        }
'''
PLAN_NEW = PLAN + r'''
        if !isUsingStreamPlayer, !nextTrack.isStream, !current.isStream {
            AutoMixController.shared.prepare(outgoing: current, outgoingDuration: totalDur, incoming: nextTrack, mode: transitionMode, crossfadeDuration: crossfadeDuration)
            if let decision = AutoMixController.shared.decision(for: nextTrack.id) {
                plan.blendDuration = decision.duration
                plan.cueTime = decision.cueTime
            }
        }
'''
ENTRY = r'''        Task {
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile

                let frameCount = AVAudioFrameCount(nextFile.length)
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: 0, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
'''
ENTRY_NEW = r'''        let decision = AutoMixController.shared.decision(for: nextTrack.id)
        Task {
            do {
                let nextFile = try AVAudioFile(forReading: nextTrack.url)
                self.incomingAudioFile = nextFile
                let incomingRate: Float = (decision?.isBeatMatched ?? false) ? (decision?.tempoRate ?? 1) : 1
                self.setIncomingPlaybackRate(incomingRate)
                let sampleRate = nextFile.processingFormat.sampleRate
                let requested = AVAudioFramePosition(max(0, decision?.incomingStart ?? 0) * sampleRate)
                let startFrame = max(0, min(requested, max(0, nextFile.length - 1)))
                let frameCount = AVAudioFrameCount(max(0, nextFile.length - startFrame))
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: startFrame, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
'''
PLAY = r'''                targetIdlePlayer.volume = 0
                if !self.engine.isRunning { try? self.engine.start() }
                targetIdlePlayer.play()
'''
PLAY_NEW = r'''                targetIdlePlayer.volume = 0
                if !self.engine.isRunning { try? self.engine.start() }
                // Both operations are submitted in one main-actor turn, so the
                // loop downbeat and B's downbeat enter the same render quantum.
                if let decision { self.startOutgoingBeatLoop(decision) }
                targetIdlePlayer.play()
'''
AUTO = r'''        let style = AutoMixDJEngine.shared.activeStyle
        let (outVol, inVol, outBassCut, inBassGain) = AutoMixDJEngine.shared.computeVolumesAndEQ(progress: p, style: style)
'''
AUTO_NEW = r'''        let style = AutoMixDJEngine.shared.activeStyle
        var (outVol, inVol, outBassCut, inBassGain) = AutoMixDJEngine.shared.computeVolumesAndEQ(progress: p, style: style)
        var outHighCut: Float = 0
        var inHighCut: Float = 0
        var outReverb: Float = 0
        var inReverb: Float = 0
        if let automation = AutoMixController.shared.automation(progress: p) {
            outVol = automation.outgoingVolume; inVol = automation.incomingVolume
            outBassCut = automation.outgoingBassCutDB; inBassGain = automation.incomingBassGainDB
            outHighCut = automation.outgoingHighCutDB; inHighCut = automation.incomingHighCutDB
            outReverb = automation.outgoingReverbMix; inReverb = automation.incomingReverbMix
        }
'''
VOLUME = r'''            activePlayer.volume = outVol * volume
            idlePlayer.volume = inVol * volume
'''
VOLUME_NEW = r'''            setOutgoingTransitionVolume(outVol * volume)
            idlePlayer.volume = inVol * volume
            setTransitionEffects(outgoingHighCutDB: outHighCut, incomingHighCutDB: inHighCut, outgoingReverbMix: outReverb, incomingReverbMix: inReverb)
'''
PROMOTE = r'''            promoted = max(0, transitionDuration)
'''
PROMOTE_NEW = r'''            promoted = AutoMixController.shared.promotedOffset(blend: max(0, transitionDuration))
'''
RELEASE = r'''        incomingTrack = nil
        prebufferedTrackId = nil
        clearAutoMixPreparation()
'''
RELEASE_NEW = r'''        finishTransitionEffects()
        AutoMixController.shared.finishTransition()
        incomingTrack = nil
        prebufferedTrackId = nil
        clearAutoMixPreparation()
'''
CANCEL = r'''        incomingAudioFile = nil
        isTransitioning = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        applyEQ()
'''
CANCEL_NEW = r'''        incomingAudioFile = nil
        isTransitioning = false
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
        AutoMixController.shared.cancel()
        resetPlaybackRates()
        cancelTransitionEffects()
        applyEQ()
'''
ANCHOR = r'''    private func liveProgress() -> Double {
'''
ANCHOR_NEW = r'''    func nudgePlaybackAnchor(by seconds: Double) {
        guard seconds.isFinite, abs(seconds) > 0.0001 else { return }
        anchorOffset = max(0, anchorOffset + seconds)
        pausedProgress = max(0, pausedProgress + seconds)
    }

    private func liveProgress() -> Double {
'''

def main():
    text = PLAYER.read_text(encoding="utf-8")
    for args in [
        (PLAN, PLAN_NEW, "AutoMixController.shared.prepare(", "planner"),
        (ENTRY, ENTRY_NEW, "let incomingRate: Float", "entry"),
        (PLAY, PLAY_NEW, "startOutgoingBeatLoop(decision)", "loop start"),
        (AUTO, AUTO_NEW, "var outReverb: Float", "automation"),
        (VOLUME, VOLUME_NEW, "setOutgoingTransitionVolume", "FX volume"),
        (PROMOTE, PROMOTE_NEW, "AutoMixController.shared.promotedOffset", "position"),
        (RELEASE, RELEASE_NEW, "finishTransitionEffects()", "FX release"),
        (CANCEL, CANCEL_NEW, "cancelTransitionEffects()", "FX cancel"),
        (ANCHOR, ANCHOR_NEW, "func nudgePlaybackAnchor", "anchor")]:
        text = patch(text, *args)
    PLAYER.write_text(text, encoding="utf-8")
    print("fully automatic AutoMix wired")

if __name__ == "__main__": sys.exit(main())
