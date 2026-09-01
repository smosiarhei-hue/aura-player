#!/usr/bin/env python3
"""Install local DJ audio graph: time-pitch, EQ, reverb and beat-loop deck."""

import sys
from pathlib import Path
PLAYER = Path("Aurora/playercore.swift")

def patch(text, anchor, replacement, marker, label):
    if marker in text: return text
    if text.count(anchor) != 1: raise RuntimeError(label + ": anchor not found exactly once")
    return text.replace(anchor, replacement, 1)

NODES = r'''    private let eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
'''
NODES_NEW = r'''    private let eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let timePitchA = AVAudioUnitTimePitch()
    private let timePitchB = AVAudioUnitTimePitch()
    private let reverbA = AVAudioUnitReverb()
    private let reverbB = AVAudioUnitReverb()
    private let beatLoopPlayer = AVAudioPlayerNode()
    private let beatLoopEQ = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let beatLoopReverb = AVAudioUnitReverb()
    private var isBeatLoopActive = false
'''
GRAPH = r'''        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(eqNodeA)
        engine.attach(eqNodeB)

        configureEQ(eqNodeA)
        configureEQ(eqNodeB)

        engine.connect(playerA, to: eqNodeA, format: nil)
        engine.connect(playerB, to: eqNodeB, format: nil)
        engine.connect(eqNodeA, to: engine.mainMixerNode, format: nil)
        engine.connect(eqNodeB, to: engine.mainMixerNode, format: nil)
'''
GRAPH_NEW = r'''        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(timePitchA)
        engine.attach(timePitchB)
        engine.attach(eqNodeA)
        engine.attach(eqNodeB)
        engine.attach(reverbA)
        engine.attach(reverbB)
        engine.attach(beatLoopPlayer)
        engine.attach(beatLoopEQ)
        engine.attach(beatLoopReverb)

        configureEQ(eqNodeA)
        configureEQ(eqNodeB)
        configureEQ(beatLoopEQ)
        configureTimePitch(timePitchA)
        configureTimePitch(timePitchB)
        configureReverb(reverbA)
        configureReverb(reverbB)
        configureReverb(beatLoopReverb)

        engine.connect(playerA, to: timePitchA, format: nil)
        engine.connect(playerB, to: timePitchB, format: nil)
        engine.connect(timePitchA, to: eqNodeA, format: nil)
        engine.connect(timePitchB, to: eqNodeB, format: nil)
        engine.connect(eqNodeA, to: reverbA, format: nil)
        engine.connect(eqNodeB, to: reverbB, format: nil)
        engine.connect(reverbA, to: engine.mainMixerNode, format: nil)
        engine.connect(reverbB, to: engine.mainMixerNode, format: nil)
        engine.connect(beatLoopPlayer, to: beatLoopEQ, format: nil)
        engine.connect(beatLoopEQ, to: beatLoopReverb, format: nil)
        engine.connect(beatLoopReverb, to: engine.mainMixerNode, format: nil)
'''
ACCESS = r'''    private var activeEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeA : eqNodeB }
    private var idleEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeB : eqNodeA }
    private var idlePlayer: AVAudioPlayerNode { (activePlayer === playerA) ? playerB : playerA }
'''
ACCESS_NEW = r'''    private var activeEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeA : eqNodeB }
    private var idleEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeB : eqNodeA }
    private var idlePlayer: AVAudioPlayerNode { (activePlayer === playerA) ? playerB : playerA }
    private var activeReverb: AVAudioUnitReverb { (activePlayer === playerA) ? reverbA : reverbB }
    private var idleReverb: AVAudioUnitReverb { (activePlayer === playerA) ? reverbB : reverbA }

    private func configureTimePitch(_ node: AVAudioUnitTimePitch) {
        node.rate = 1; node.pitch = 0; node.overlap = 8; node.bypass = true
    }

    private func configureReverb(_ node: AVAudioUnitReverb) {
        node.loadFactoryPreset(.largeHall2)
        node.wetDryMix = 0
        node.bypass = true
    }

    private var activeTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchA : timePitchB }
    private var idleTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchB : timePitchA }

    func setOutgoingPlaybackRate(_ rate: Float) { applyPlaybackRate(rate, to: activeTimePitch) }
    func setIncomingPlaybackRate(_ rate: Float) { applyPlaybackRate(rate, to: idleTimePitch) }
    func rampIncomingPlaybackRate(target: Float, progress: Double) { TimeStretchEngine.applyRamp(target: target, progress: progress, to: idleTimePitch) }
    func resetPlaybackRates() { applyPlaybackRate(1, to: timePitchA); applyPlaybackRate(1, to: timePitchB) }
    var outgoingPlaybackRate: Float { activeTimePitch.rate }
    var incomingPlaybackRate: Float { idleTimePitch.rate }

    private func applyPlaybackRate(_ rate: Float, to node: AVAudioUnitTimePitch) {
        let clamped = min(TimeStretchEngine.maxRate, max(TimeStretchEngine.minRate, rate))
        node.rate = clamped
        node.bypass = abs(clamped - 1) < 0.0005
    }

    func startOutgoingBeatLoop(_ decision: TransitionDecision) {
        guard decision.usesBeatLoop, let track = currentTrack else { return }
        do {
            let file = try AVAudioFile(forReading: track.url)
            let rate = file.processingFormat.sampleRate
            let start = max(0, AVAudioFramePosition((decision.outgoingLoopStart ?? decision.cueTime) * rate))
            let available = max(0, file.length - start)
            let requested = AVAudioFramePosition(decision.outgoingLoopDuration * rate)
            let count = AVAudioFrameCount(min(available, max(1, requested)))
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return }
            file.framePosition = start
            try file.read(into: buffer, frameCount: count)
            beatLoopPlayer.stop()
            beatLoopPlayer.volume = activePlayer.volume
            beatLoopPlayer.scheduleBuffer(buffer, at: nil, options: .loops)
            activePlayer.stop()
            beatLoopPlayer.play()
            isBeatLoopActive = true
        } catch {
            isBeatLoopActive = false
        }
    }

    func setOutgoingTransitionVolume(_ value: Float) {
        if isBeatLoopActive { beatLoopPlayer.volume = value } else { activePlayer.volume = value }
    }

    func setTransitionEffects(outgoingHighCutDB: Float, incomingHighCutDB: Float, outgoingReverbMix: Float, incomingReverbMix: Float) {
        let outgoingEQ = isBeatLoopActive ? beatLoopEQ : activeEQ
        for index in 7..<10 {
            let base = eqEnabled ? eqGains[index] : 0
            outgoingEQ.bands[index].gain = max(-48, base + outgoingHighCutDB)
            idleEQ.bands[index].gain = max(-48, base + incomingHighCutDB)
        }
        let outgoingVerb = isBeatLoopActive ? beatLoopReverb : activeReverb
        outgoingVerb.bypass = outgoingReverbMix < 0.1
        outgoingVerb.wetDryMix = min(100, max(0, outgoingReverbMix))
        idleReverb.bypass = incomingReverbMix < 0.1
        idleReverb.wetDryMix = min(100, max(0, incomingReverbMix))
    }

    func finishTransitionEffects() {
        beatLoopPlayer.stop()
        isBeatLoopActive = false
        activeReverb.bypass = true
        activeReverb.wetDryMix = 0
        let oldReverb = idleReverb
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            oldReverb.wetDryMix = 0
            oldReverb.bypass = true
            self.beatLoopReverb.wetDryMix = 0
            self.beatLoopReverb.bypass = true
            self.applyEQ()
        }
    }

    func cancelTransitionEffects() {
        beatLoopPlayer.stop(); isBeatLoopActive = false
        for node in [reverbA, reverbB, beatLoopReverb] { node.wetDryMix = 0; node.bypass = true }
        applyEQ()
    }
'''

def main():
    if not PLAYER.exists(): raise RuntimeError("missing " + str(PLAYER))
    text = PLAYER.read_text(encoding="utf-8")
    text = patch(text, NODES, NODES_NEW, "private let beatLoopPlayer", "DJ nodes")
    text = patch(text, GRAPH, GRAPH_NEW, "engine.connect(beatLoopPlayer", "DJ graph")
    text = patch(text, ACCESS, ACCESS_NEW, "func startOutgoingBeatLoop", "DJ APIs")
    PLAYER.write_text(text, encoding="utf-8")
    print("automatic DJ audio graph ready")

if __name__ == "__main__": sys.exit(main())
