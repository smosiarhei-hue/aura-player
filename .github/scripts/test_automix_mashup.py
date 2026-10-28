#!/usr/bin/env python3
"""Source-shape checks for AutoMix Mashup (DJ vocal↔instrumental live path)."""

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
        self.assertIn("VOCAL HOLD", models)
        self.assertIn("SOFT REVEAL", models)
        # Equal-power volume contract stays intact for CI purity checks.
        self.assertIn("return (outVol, inVol, 0.0, 0.0, 1.0)", models)

        player = (ROOT / "Sonivo/playercore.swift").read_text()
        self.assertIn("transitionMode == .crossfade || transitionMode == .automix", player)
        self.assertIn("applyMashupTransitionEQ(progress: p)", player)
        self.assertIn("applyMashupTransitionEQ(progress: 0)", player)
        self.assertIn("setItemEQOverride", player)
        self.assertIn("clearItemEQOverrides", player)
        self.assertIn("CrossfadeCurve.gains(progress: p)", player)
        # Per-pair beatmatch mashup (BPM rates + vocal↔instrumental), not FX-only.
        self.assertIn("resolveMashupStyle", player)
        self.assertIn("activeMashupStyle.volumes", player)
        self.assertIn("activeMashupStyle.playbackRates", player)
        self.assertIn("MashupLiveStyle.resolve", player)
        self.assertIn("applyMashupTimePitch", player)
        self.assertIn("playImmediately(atRate: startRate)", player)
        # Auto blend-point detection (outro/intro), not fixed end-seconds alone.
        self.assertIn("resolveMashupBlend", player)
        self.assertIn("MashupBlendScheduler.schedule", player)
        self.assertIn("defaultPreferredBlendSec", player)
        self.assertNotIn("crossfadeDuration * 1.35", player)
        self.assertIn("incomingStartPosition + elapsed", player)
        # Stream intro seek must use completion-handler overload (Swift 6 async seek needs await).
        self.assertIn(
            "targetStream.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }",
            player,
        )

    def test_blend_scheduler_exists(self):
        scheduler = (
            ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupBlendScheduler.swift"
        ).read_text()
        self.assertIn("enum MashupBlendScheduler", scheduler)
        self.assertIn("minimumPlayedFraction", scheduler)
        self.assertIn("heuristicCues", scheduler)
        self.assertIn("LiveMashupBlend", scheduler)
        self.assertIn("defaultPreferredBlendSec", scheduler)
        self.assertIn("not a settings slider", scheduler)
        tests = (ROOT / "Tests/UnitTests/MashupBlendSchedulerTests.swift").read_text()
        self.assertIn("MashupBlendSchedulerTests", tests)
        self.assertIn("preferredDoesNotCapNaturalBlend", tests)

        presentation = (ROOT / "Sonivo/ActivePlayerPresentation.swift").read_text()
        self.assertIn("mashupPhaseLabel", presentation)
        badge = (ROOT / "Sonivo/Dify/AIDJTransitionBadgeView.swift").read_text()
        self.assertIn("phaseLabel", badge)
        self.assertIn("l10n.automix", badge)
        self.assertIn("exposureAdjust", badge)
        self.assertIn("headroom", badge)
        self.assertIn("extendedLinear", badge)
        self.assertIn("plusLighter", badge)
        l10n = (ROOT / "Sonivo/SonivoL10n.swift").read_text()
        self.assertIn("var automix", l10n)
        self.assertIn("Автомикс", l10n)
        self.assertIn("func automixPhase", l10n)
        screen = (ROOT / "Sonivo/PlayerScreenV2.swift").read_text()
        self.assertIn("player.mashupPhaseLabel", screen)

        tap = (ROOT / "Sonivo/streambeat.swift").read_text()
        self.assertIn("itemEQOverrides", tap)
        self.assertIn("func setItemEQOverride", tap)
        self.assertIn("func clearItemEQOverrides", tap)
        # Shared updateEQ must remain download-free (realtime-eq contract).
        self.assertNotIn("download", tap.split("func updateEQ", 1)[1].split("func setItemEQOverride", 1)[0])

        settings = (ROOT / "Sonivo/settingsview.swift").read_text()
        self.assertIn("TransitionMode.automix", settings)
        # Duration slider is crossfade-only; mashup auto-adjusts from blend detection.
        self.assertIn("player.transitionMode == .crossfade", settings)
        self.assertNotIn("Длительность mashup", settings)
        self.assertIn("beatmatch", settings.lower())
        self.assertIn("вокал", settings.lower())

        runner = (ROOT / "Sonivo/MixPlanRealtimeTransitionRunner.swift").read_text()
        self.assertIn("MashupTransitionExecutor", runner)
        self.assertIn("enum MashupLiveEQEnvelope", runner)
        self.assertIn("MashupLiveStyle", runner)
        self.assertIn("inVocalPocket", runner)
        self.assertIn("outHPFBody", runner)

        style = (
            ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift"
        ).read_text()
        self.assertIn("struct MashupLiveStyle", style)
        self.assertIn("func volumes(progress", style)
        self.assertIn("func playbackRates(progress", style)
        self.assertIn("isBeatmatched", style)
        self.assertIn("tempoMatch", style)
        self.assertIn("static func resolve", style)
        self.assertIn("fromPlan", style)
        self.assertIn("BEATMATCH", style)

        analysis = (ROOT / "Sonivo/AutoMixV2AnalysisRuntime.swift").read_text()
        self.assertIn("transitionMode == .automix", analysis)
        self.assertIn("shouldAnalyse", analysis)
        self.assertIn("allowDownload", analysis)

    def test_drop_swap_plan_still_encodes_mashup_fx(self):
        planner = (ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift").read_text()
        self.assertIn("case .seamlessLoop", planner)
        self.assertIn("kind: .bassKill", planner)
        self.assertIn("kind: .vocalDucking", planner)
        self.assertIn("kind: .echoOut", planner)

    def test_docs_describe_auto_duration_and_live_eq(self):
        docs = (ROOT / "docs/automix-mashup.md").read_text()
        self.assertIn("инструментал B под вокал A", docs)
        self.assertIn("Beatmatch", docs)
        self.assertIn("MashupLiveStyle", docs)
        self.assertIn("под каждую пару", docs)
        self.assertIn("rateA", docs)
        self.assertIn("force-disabled", docs)


if __name__ == "__main__":
    unittest.main()
