#!/usr/bin/env python3
"""Regression: field session 1.0.1058 (1107) bake/LAND 'dta?' chain.

Log pattern that must not recur after AVAssetReader decode:
  bake.htdemucs → bake.fail (dta?) → fallback.file (dta?) → stream
  land.hardcut syncLocal=2 glide=0.00 → land.recover frozen=1

Expected after this fix:
  decodeCompressedToFloat32CAF tries AVAudioFile then AVAssetReader
  openPlaybackSource always private-copies m4a/mp3 before open
  fallback arms native file (not stream) when CAF materializes
  land uses syncLocal=1 + land glide when local handoff works
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BAKER = (
    ROOT / "Packages/AutoMixV2/Sources/AudioEngineCore/MidSideStemBaker.swift"
).read_text()
PLAYER = (ROOT / "Sonivo/playercore.swift").read_text()
MOOD = (
    ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MoodAutomix.swift"
).read_text()


class AutomixDtaFallbackTests(unittest.TestCase):
    def test_decode_chain_bypasses_avaudiofile_dta(self):
        self.assertIn("decodeCompressedViaAVAudioFile", BAKER)
        self.assertIn("decodeCompressedViaAVAssetReader", BAKER)
        self.assertIn("AVAssetReader(asset:", BAKER)
        self.assertIn("1685348671", BAKER)
        self.assertIn("'dta?'", BAKER)
        # Public entry must fall through when ExtAudioFile open fails.
        body = BAKER.split("func decodeCompressedToFloat32CAF", 1)[1].split(
            "private static func decodeCompressedViaAVAudioFile", 1
        )[0]
        self.assertIn("decodeCompressedViaAVAudioFile", body)
        self.assertIn("decodeCompressedViaAVAssetReader", body)
        self.assertLess(
            BAKER.index("decodeCompressedViaAVAudioFile"),
            BAKER.index("decodeCompressedViaAVAssetReader"),
        )

    def test_playback_open_never_locks_live_m4a(self):
        self.assertIn('needsPrivateCopy = ["m4a", "mp3", "aac", "m4b", "mp4"]', BAKER)
        open_fn = BAKER.split("func openPlaybackSource", 1)[1].split(
            "func decodeCompressedToFloat32CAF", 1
        )[0]
        self.assertIn("needsPrivateCopy", open_fn)
        self.assertIn("copyItem", open_fn)
        self.assertIn("decodeCompressedToFloat32CAF", open_fn)
        # Must not return a successful live open of compressed caches.
        self.assertIn("if !needsPrivateCopy", open_fn)

    def test_fallback_prefers_native_file_over_stream(self):
        self.assertIn("openAutomixPlaybackFile", PLAYER)
        self.assertIn("fallback.file", PLAYER)
        self.assertIn("localIncomingURL = inURLForBake ?? nextURL", PLAYER)
        # Live FX path kept even when bake fails (not silent crossfade wipe).
        self.assertIn("live Automix FX", PLAYER)
        self.assertNotIn("→ crossfade fallback", PLAYER)

    def test_land_glide_when_local_handoff_succeeds(self):
        self.assertIn("landAutomixOntoDryB", PLAYER)
        self.assertIn("startLandGlide", PLAYER)
        self.assertIn("syncLocal = 1", PLAYER)
        self.assertIn("syncLocal = 2", PLAYER)
        # Glide duration still present for mood land.
        self.assertIn("glideSec", PLAYER)
        self.assertIn("moodLand", PLAYER)

    def test_track_end_during_prepare_never_deadlocks(self):
        # Field: Automix fails/prepares late → A ends → old code returned and
        # left a silent deck with no next song.
        finish = PLAYER.split("private func handleTrackFinish()", 1)[1].split(
            "private var lastRefillCheck", 1
        )[0]
        # Prefer hard-complete when B was pre-opened / queued (field starve with
        # incomingAudioFile set but txReady still 0).
        self.assertIn("transition.starve → complete armed B", finish)
        self.assertIn("completeTransition(to: target)", finish)
        self.assertIn("transition.starve → next", finish)
        self.assertIn("force next", finish)
        self.assertIn("giveUpMashupAndKeepPlaying", finish)
        self.assertNotIn(
            'SonivoDiagnostics.log("[AutoMix] Track ended while the mix is still preparing", tag: "AUTOMIX")\n                return',
            finish,
        )
        self.assertIn("transition.lane-missing → next", finish)
        self.assertIn("B still playing", finish)
        give_up = PLAYER.split("private func giveUpMashupAndKeepPlaying", 1)[1].split(
            "private func scheduleTransitionIfNeeded", 1
        )[0]
        self.assertIn("nativeSilent", give_up)
        self.assertIn("streamSilent", give_up)
        self.assertIn("isPlaying = true", give_up)
        # Field 1076: completeTransition must kill prep so bake.pending cannot
        # resurrect MIXING after land.hardcut (zombie badge / cascade hardcut).
        complete = PLAYER.split("private func completeTransition(to nextTrack: Track)", 1)[1].split(
            "private func releaseActiveTimePitchToUnity", 1
        )[0]
        self.assertIn("transitionPreparationTask?.cancel()", complete)
        self.assertIn("transitionRequestID = UUID()", complete)
        self.assertIn("pendingMashupLiveArm = nil", complete)
        # Field 1129: session log must not hard-zero volB when stream A + local B.
        probe = PLAYER.split("var idleDeckVolumePublic: Float", 1)[1].split(
            "var mashupLockedRateAPublic", 1
        )[0]
        self.assertIn("return idlePlayer.volume", probe)
        self.assertNotIn("if isUsingStreamPlayer { return 0 }", probe)
        # New schedule must clear leftover MIXING timer from a zombie arm.
        schedule = PLAYER.split("private func scheduleSimpleTransition(", 1)[1].split(
            "transitionPreparationTask = Task", 1
        )[0]
        self.assertIn("transitionTimer?.invalidate()", schedule)
        self.assertIn("transitionStartTime = nil", schedule)
        self.assertIn("incomingLaneReady = false", schedule)
        self.assertIn("pendingMashupLiveArm = nil", schedule)

    def test_provisional_scan_not_thirty_second_silent_prep(self):
        # User log had blend windows 16–26s with mood.scan miss — provisional
        # scan must stay short so the cue path can start live FX early.
        self.assertIn("private static func provisional", MOOD)
        self.assertIn("clamp(dur * 0.07, min: 8, max: 12)", MOOD)
        self.assertIn('mood: "scan"', MOOD)
        # Must not advertise a 22s silent prep runway again.
        self.assertIn("22s silent", MOOD)


if __name__ == "__main__":
    unittest.main()
