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
    def test_detects_freeze_and_bake_without_ready(self):
        result = MOD.analyze(SAMPLE_FREEZE)
        self.assertEqual(result["verdict"], "broken")
        self.assertIn("playback_frozen", result["problems"])
        self.assertIn("bake_started_without_ready", result["problems"])
        self.assertTrue(result["had_bake_start"])
        self.assertFalse(result["had_bake_ready"])

    def test_script_exists(self):
        self.assertTrue((ROOT / "tools" / "analyze_automix_session_log.py").is_file())


if __name__ == "__main__":
    unittest.main()
