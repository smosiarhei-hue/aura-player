#!/usr/bin/env python3
"""Unit tests for tools/analyze_automix_session_log.py."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "analyze_automix_session_log",
    ROOT / "tools" / "analyze_automix_session_log.py",
)
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MOD)


SAMPLE_FREEZE = """
Sonivo AutoMix Session Log
[04:05:05.825][EVENT] bake.start blend=32.0s
[04:05:06.840][TICK] mode=automix play=1 stream=1 tx=1 txReady=1 txP=0.024 badge=MIXING pos=163.7 dur=184.1 dispPos=163.7 A=A#1 B=B#2 UI=A#1 bake=0 volA=1.00 volB=1.00 err=-
[04:05:27.835][TICK] mode=automix play=1 stream=1 tx=0 txReady=0 txP=0.000 badge=- pos=16.0 dur=247.1 dispPos=16.0 A=B#2 B=- UI=B#2 bake=0 volA=1.00 volB=0.00 err=-
[04:05:28.835][TICK] mode=automix play=1 stream=1 tx=0 txReady=0 txP=0.000 badge=- pos=16.0 dur=247.1 dispPos=16.0 A=B#2 B=- UI=B#2 bake=0 volA=1.00 volB=0.00 err=-
[04:05:29.835][TICK] mode=automix play=1 stream=1 tx=0 txReady=0 txP=0.000 badge=- pos=16.0 dur=247.1 dispPos=16.0 A=B#2 B=- UI=B#2 bake=0 volA=1.00 volB=0.00 err=-
[04:05:30.835][TICK] mode=automix play=1 stream=1 tx=0 txReady=0 txP=0.000 badge=- pos=16.0 dur=247.1 dispPos=16.0 A=B#2 B=- UI=B#2 bake=0 volA=1.00 volB=0.00 err=-
[04:05:31.835][TICK] mode=automix play=1 stream=1 tx=0 txReady=0 txP=0.000 badge=- pos=16.0 dur=247.1 dispPos=16.0 A=B#2 B=- UI=B#2 bake=0 volA=1.00 volB=0.00 err=-
[04:05:32.835][TICK] mode=automix play=1 stream=1 tx=0 txReady=0 txP=0.000 badge=- pos=16.0 dur=247.1 dispPos=16.0 A=B#2 B=- UI=B#2 bake=0 volA=1.00 volB=0.00 err=-
[04:05:33.000][FAULT] playback.frozen pos=16.0 dur=247.1 tx=0 bake=0 stream=1 track=B
"""


class AnalyzeAutoMixSessionLogTests(unittest.TestCase):
    def test_safe_fade_completion_does_not_require_land(self):
        sample = """
[01:00:00.000][EVENT] transition.schedule mode=automix
[01:00:00.010][EVENT] transition.decision exec=safe-fade plan=crossfade pairMatch=1
[01:00:04.000][EVENT] transition.handoff-attempt exec=safe-fade progress=1.000 bReady=1 bState=playing
[01:00:04.001][EVENT] transition.promoted exec=safe-fade position=4.00 backend=stream
[01:00:05.000][TICK] play=1 tx=0 pos=4.0 A=B#2 B=-
"""
        result = MOD.analyze(sample)
        self.assertEqual(result["verdict"], "no_issue_detected")
        self.assertNotIn("missing_land_event", result["problems"])
        self.assertEqual(result["execution_decisions"][0]["exec"], "safe-fade")
        self.assertEqual(result["transition_completions"][0]["position"], "4.00")
        self.assertNotIn("transition_outcome_unconfirmed", result["limitations"])

    def test_partial_schedule_is_not_a_proven_failure(self):
        result = MOD.analyze("[01:00:00.000][EVENT] transition.schedule mode=automix\n[01:00:01.000][TICK] play=1 tx=0 pos=1.0")
        self.assertNotEqual(result["verdict"], "broken")
        self.assertIn("transition_outcome_unconfirmed", result["limitations"])

    def test_later_incomplete_transition_is_not_masked_by_earlier_completion(self):
        sample = """
[01:00:00.000][EVENT] transition.schedule mode=automix
[01:00:01.000][EVENT] transition.promoted exec=safe-fade
[01:00:02.000][EVENT] transition.schedule mode=automix
"""
        result = MOD.analyze(sample)
        self.assertEqual(result["unconfirmed_transitions"], 1)
        self.assertEqual(result["verdict"], "insufficient_data")

    def test_action_snapshots_and_buffering_are_not_a_freeze(self):
        states = "\n".join(f"[01:00:00.{i:03}][STATE] play=1 pos=1.0 A=track" for i in range(8))
        ticks = "\n".join(f"[01:00:{i:02}.000][TICK] play=1 bufferA=1 pos=1.0 A=track" for i in range(1, 8))
        self.assertNotIn("playback_frozen", MOD.analyze(states + "\n" + ticks)["problems"])

    def test_empty_or_unrecognized_report_is_inconclusive(self):
        self.assertEqual(MOD.analyze("Sonivo AutoMix Session Log\n")["verdict"], "insufficient_data")

    def test_detects_freeze_and_bake_without_ready(self):
        result = MOD.analyze(SAMPLE_FREEZE)
        self.assertEqual(result["verdict"], "broken")
        self.assertIn("playback_frozen", result["problems"])
        self.assertIn("bake_started_without_ready", result["problems"])
        self.assertTrue(result["had_bake_start"])
        self.assertFalse(result["had_bake_ready"])

    def test_app_report_has_bounded_context_and_route_evidence(self):
        log = (ROOT / "Sonivo/AutoMixSessionLog.swift").read_text()
        core = (ROOT / "Sonivo/playercore.swift").read_text()
        settings = (ROOT / "Sonivo/settingsview.swift").read_text()
        for token in ("maxExportLines = 300", "lines.suffix(maxExportLines)",
                      "Earlier lines discarded", "rateSource=planned-style",
                      "core.incomingPlaybackStatePublic", "if isEnabled, PlayerCore.isSharedReady"):
            self.assertIn(token, log)
        for token in ("transition.decision exec=", "transition.started exec=",
                      "transition.promoted exec=", "transition.safe-wait", "transition.safe-abort"):
            self.assertIn(token, core)
        self.assertIn("Автоматической отправки нет", settings)

    def test_script_exists(self):
        self.assertTrue((ROOT / "tools" / "analyze_automix_session_log.py").is_file())

    def test_detects_skip_after_land(self):
        sample = """
[04:31:34.616][EVENT] land.hardcut B=TrackB pos=36.5 proposed=36.5 syncLocal=0
[04:31:34.647][ACTION] next | from=TrackB to=TrackC
[04:31:34.895][TICK] mode=automix play=1 stream=1 tx=0 pos=0.0 A=TrackC#1 B=-
"""
        result = MOD.analyze(sample)
        self.assertIn("possible_skip_after_land", result["problems"])
        self.assertEqual(result["verdict"], "degraded")

    def test_detects_dual_full_stem_mixing(self):
        sample = """
[05:30:41.848][EVENT] bake.ready automix lag=0.11s cueA=167.8 cueB=16.1 rateA=1.000 rateB=1.000 pitchB=0 bed=0.70
[05:30:42.928][TICK] mode=automix play=1 tx=1 badge=MIXING bake=1 volA=1.00 volB=1.00 pos=168.9
[05:30:43.928][TICK] mode=automix play=1 tx=1 badge=MIXING bake=1 volA=1.00 volB=1.00 pos=169.9
[05:30:44.928][TICK] mode=automix play=1 tx=1 badge=MIXING bake=1 volA=1.00 volB=1.00 pos=170.9
[05:31:09.902][EVENT] land.hardcut B=B pos=44.2 proposed=44.2 syncLocal=1
"""
        result = MOD.analyze(sample)
        self.assertIn("mixing_dual_full_volumes", result["problems"])
        self.assertEqual(result["verdict"], "degraded")
        self.assertGreaterEqual(result["mixing_dual_full_ticks"], 3)
        self.assertEqual(result["bake_ready_meta"][0].get("bed"), "0.70")


if __name__ == "__main__":
    unittest.main()
