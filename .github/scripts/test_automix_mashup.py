#!/usr/bin/env python3
"""Source-shape checks for AutoMix Mashup (DJ bass-swap path)."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class AutoMixMashupTests(unittest.TestCase):
    def test_executor_and_pitch_api_exist(self):
        executor = (ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupTransitionExecutor.swift").read_text()
        self.assertIn("struct MashupTransitionExecutor", executor)
        self.assertIn("protocol MashupTransitionAudio", executor)
        self.assertIn("setPitchCents", executor)
        self.assertIn("EffectAutomation.value", executor)

        deck = (ROOT / "Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift").read_text()
        self.assertIn("func setPitchCents", deck)

    def test_live_player_enables_automix_mashup(self):
        models = (ROOT / "Sonivo/models.swift").read_text()
        self.assertIn('case automix = "AutoMix Mashup"', models)
        self.assertIn("markMashupProgress", models)
        # Equal-power volume contract stays intact for CI purity checks.
        self.assertIn("return (outVol, inVol, 0.0, 0.0, 1.0)", models)

        player = (ROOT / "Sonivo/playercore.swift").read_text()
        self.assertIn("transitionMode == .crossfade || transitionMode == .automix", player)
        self.assertIn("MashupLiveEQEnvelope.offsets", player)
        self.assertIn("CrossfadeCurve.gains(progress: p)", player)

        settings = (ROOT / "Sonivo/settingsview.swift").read_text()
        self.assertIn("TransitionMode.automix", settings)

        runner = (ROOT / "Sonivo/MixPlanRealtimeTransitionRunner.swift").read_text()
        self.assertIn("MashupTransitionExecutor", runner)
        self.assertIn("enum MashupLiveEQEnvelope", runner)

    def test_drop_swap_plan_still_encodes_mashup_fx(self):
        planner = (ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift").read_text()
        self.assertIn("case .seamlessLoop", planner)
        self.assertIn("kind: .bassKill", planner)
        self.assertIn("kind: .vocalDucking", planner)
        self.assertIn("kind: .echoOut", planner)


if __name__ == "__main__":
    unittest.main()
