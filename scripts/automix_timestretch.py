#!/usr/bin/env python3
"""Insert an AVAudioUnitTimePitch stage into both local playback lanes.

Graph after this patch:

    playerA -> timePitchA -> eqNodeA -> mainMixerNode
    playerB -> timePitchB -> eqNodeB -> mainMixerNode

The nodes are bypassed while the rate is 1.0, so outside an AutoMix tempo ramp
there is no CPU or latency cost. Rates are driven by
Aurora/AutoMix/TimeStretchEngine.swift.
"""

import sys
from pathlib import Path

PLAYER = Path("Aurora/playercore.swift")


def patch(text, anchor, replacement, marker, label):
    if marker in text:
        print("skip (already applied): " + label)
        return text
    if text.count(anchor) != 1:
        raise RuntimeError(label + ": required source anchor was not found exactly once")
    print("applied: " + label)
    return text.replace(anchor, replacement)


NODES_ANCHOR = r'''    private let eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
'''

NODES_REPLACEMENT = r'''    private let eqNodeA = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
    private let eqNodeB = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)

    // Time-stretch stage per lane, driven by AutoMix/TimeStretchEngine.swift.
    private let timePitchA = AVAudioUnitTimePitch()
    private let timePitchB = AVAudioUnitTimePitch()
'''

GRAPH_ANCHOR = r'''        engine.attach(playerA)
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

GRAPH_REPLACEMENT = r'''        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(timePitchA)
        engine.attach(timePitchB)
        engine.attach(eqNodeA)
        engine.attach(eqNodeB)

        configureEQ(eqNodeA)
        configureEQ(eqNodeB)
        configureTimePitch(timePitchA)
        configureTimePitch(timePitchB)

        engine.connect(playerA, to: timePitchA, format: nil)
        engine.connect(playerB, to: timePitchB, format: nil)
        engine.connect(timePitchA, to: eqNodeA, format: nil)
        engine.connect(timePitchB, to: eqNodeB, format: nil)
        engine.connect(eqNodeA, to: engine.mainMixerNode, format: nil)
        engine.connect(eqNodeB, to: engine.mainMixerNode, format: nil)
'''

ACCESSORS_ANCHOR = r'''    private var activeEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeA : eqNodeB }
    private var idleEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeB : eqNodeA }
    private var idlePlayer: AVAudioPlayerNode { (activePlayer === playerA) ? playerB : playerA }
'''

ACCESSORS_REPLACEMENT = r'''    private var activeEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeA : eqNodeB }
    private var idleEQ: AVAudioUnitEQ { (activePlayer === playerA) ? eqNodeB : eqNodeA }
    private var idlePlayer: AVAudioPlayerNode { (activePlayer === playerA) ? playerB : playerA }

    private func configureTimePitch(_ node: AVAudioUnitTimePitch) {
        node.rate = 1.0
        node.pitch = 0
        node.overlap = 8
        node.bypass = true
    }

    private var activeTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchA : timePitchB }
    private var idleTimePitch: AVAudioUnitTimePitch { (activePlayer === playerA) ? timePitchB : timePitchA }

    /// AutoMix tempo sync for the outgoing lane.
    func setOutgoingPlaybackRate(_ rate: Float) {
        applyPlaybackRate(rate, to: activeTimePitch)
    }

    /// AutoMix tempo sync for the incoming lane, so its BPM matches the
    /// outgoing track before the blend starts.
    func setIncomingPlaybackRate(_ rate: Float) {
        applyPlaybackRate(rate, to: idleTimePitch)
    }

    /// Ease the incoming lane towards its target rate (CDJ style tempo ramp).
    func rampIncomingPlaybackRate(target: Float, progress: Double) {
        TimeStretchEngine.applyRamp(target: target, progress: progress, to: idleTimePitch)
    }

    func resetPlaybackRates() {
        applyPlaybackRate(1, to: timePitchA)
        applyPlaybackRate(1, to: timePitchB)
    }

    var outgoingPlaybackRate: Float { activeTimePitch.rate }
    var incomingPlaybackRate: Float { idleTimePitch.rate }

    private func applyPlaybackRate(_ rate: Float, to node: AVAudioUnitTimePitch) {
        let clamped = min(TimeStretchEngine.maxRate, max(TimeStretchEngine.minRate, rate))
        node.rate = clamped
        node.bypass = abs(clamped - 1) < 0.0005
    }
'''


def main():
    if not PLAYER.exists():
        raise RuntimeError("missing source file: " + str(PLAYER))

    text = PLAYER.read_text(encoding="utf-8")
    text = patch(text, NODES_ANCHOR, NODES_REPLACEMENT, "private let timePitchA", "time-pitch nodes")
    text = patch(text, GRAPH_ANCHOR, GRAPH_REPLACEMENT, "engine.connect(playerA, to: timePitchA", "audio graph wiring")
    text = patch(text, ACCESSORS_ANCHOR, ACCESSORS_REPLACEMENT, "func setIncomingPlaybackRate", "tempo sync API")
    PLAYER.write_text(text, encoding="utf-8")
    print("time-stretch lanes ready")


if __name__ == "__main__":
    sys.exit(main())
