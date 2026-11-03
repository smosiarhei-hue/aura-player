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
        self.assertIn('case duet = "Duet"', models)
        self.assertIn("markMashupProgress", models)
        self.assertIn("шкала и обложка снэпаются", models.lower())
        # Equal-power volume contract stays intact for CI purity checks.
        self.assertIn("return (outVol, inVol, 0.0, 0.0, 1.0)", models)

        player = (ROOT / "Sonivo/playercore.swift").read_text()
        # Automix + Duet share the beatmatched mashup path via isMashupTransitionMode.
        self.assertIn("isMashupTransitionMode", player)
        self.assertIn("transitionMode == .automix || transitionMode == .duet", player)
        self.assertIn("transitionMode == .crossfade || isMashupTransitionMode", player)
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
        # Apple Automix UI: timeline + artwork hard-cut at handoff.
        self.assertIn("displayProgress", player)
        self.assertIn("displayDuration", player)
        self.assertIn("metadataTrack ?? currentTrack", player)
        self.assertIn("activeMashupStyle.handoffAt", player)
        self.assertIn("didTriggerAutoMixDrop", player)
        # Auto blend-point detection (outro/intro), not fixed end-seconds alone.
        self.assertIn("resolveMashupBlend", player)
        self.assertIn("MashupBlendScheduler.schedule", player)
        self.assertIn("defaultPreferredBlendSec", player)
        self.assertNotIn("crossfadeDuration * 1.35", player)
        self.assertIn("incomingStartPosition + elapsed", player)
        # Stream intro seek must use completion-handler overload (Swift 6 async seek needs await),
        # then playImmediately so B is not left stalled at inCue.
        self.assertIn(
            "targetStream.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)",
            player,
        )
        self.assertIn("idleStreamingPlayer.playImmediately(atRate: startRate)", player)
        # LAND must not skip B: promote live incoming stream; suppress next() briefly.
        self.assertIn("suppressAutomixSkipUntil", player)
        self.assertIn("next.suppressed post-LAND", player)
        self.assertIn("canPromoteIncomingStream", player)
        self.assertIn("syncLocal = 2", player)

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

        timeline = (ROOT / "Sonivo/PlayerScreenV2.swift").read_text()
        self.assertIn("struct PlayerTimelineSection", timeline)
        self.assertIn("player.isTransitionActive", timeline)
        # Scrub stays live during Automix; seek cancels mashup on the live deck.
        self.assertIn("if mixing && !isScrubbing { tx.animation = nil }", timeline)
        self.assertIn("seek cancels the mashup", timeline)
        self.assertIn("player.scrubProgress", timeline)
        self.assertIn("player.scrubDuration", timeline)
        # Cover choreography may use transitionProgress; the timeline bar must not.
        self.assertIn("transitionProgress", timeline)
        self.assertIn("Never replace it with a separate mashup", timeline)
        self.assertIn(
            "min(1, max(0, effectiveProgress / timelineDuration))",
            timeline,
        )

        presentation = (ROOT / "Sonivo/ActivePlayerPresentation.swift").read_text()
        self.assertIn("legacy.displayProgress", presentation)
        self.assertIn("legacy.displayDuration", presentation)
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
        self.assertIn("TransitionMode.duet", settings)
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
        self.assertIn("dropSwap", runner)
        self.assertIn("seamlessLoop", runner)
        self.assertIn("echoFreeze", runner)
        self.assertIn("energyWash", runner)
        self.assertIn("tapeStop", runner)

        style = (
            ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift"
        ).read_text()
        self.assertIn("struct MashupLiveStyle", style)
        self.assertIn("func volumes(progress", style)
        self.assertIn("func playbackRates(progress", style)
        self.assertIn("func pitchCents(progress", style)
        self.assertIn("smoothstep", style)
        self.assertIn("tempoLockUntil", style)
        self.assertIn("isBeatmatched", style)
        self.assertIn("tempoMatch", style)
        self.assertIn("static func resolve", style)
        self.assertIn("fromPlan", style)
        self.assertIn("MIXING", style)
        self.assertIn("appleAutomixVolumes", style)
        self.assertIn("APPLE AUTOMIX", style)
        self.assertIn("oneVocalConflict", style)
        self.assertIn("isDuet", style)
        self.assertIn("DUET LOCK", style)
        self.assertIn("DUET STACK", style)
        self.assertIn("duetVolumes", style)

        runner = (ROOT / "Sonivo/MixPlanRealtimeTransitionRunner.swift").read_text()
        self.assertIn("applyOneVocalGate", runner)
        self.assertIn("applyDuetGate", runner)
        self.assertIn("oneVocalConflict", runner)
        self.assertIn("isDuet", runner)

        planner = (ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift").read_text()
        self.assertIn("Echo Out + beatmatch", planner)
        self.assertIn("bpmClose && !harmonic.isNaturallyCompatible", planner)
        self.assertIn("planDuet", planner)
        self.assertIn("planSoftDuet", planner)
        self.assertIn("case duet", (ROOT / "Packages/AutoMixV2/Sources/MixModels/MixSettings.swift").read_text())
        self.assertIn("DUET ·", planner)
        self.assertIn("maximumRateChange: 0.18", planner)
        self.assertIn("maxSemitones: 3", planner)

        style = (
            ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift"
        ).read_text()
        self.assertIn("applyDuetPlaybackCharacter", style)
        self.assertIn("applyAutomixPlaybackCharacter", style)

        player = (ROOT / "Sonivo/playercore.swift").read_text()
        self.assertIn("applyDuetPlaybackCharacter", player)
        self.assertIn("applyAutomixPlaybackCharacter", player)
        self.assertIn("Mashup/Duet need real local PCM for stem bake", player)
        self.assertIn("transitionMode == .duet || style.isDuet", player)
        self.assertIn("bakeDuetStemPair", player)
        self.assertIn("bakeAutomixStemPair", player)
        self.assertIn("playMashupStemPair", player)
        self.assertIn("isCompletingTransition", player)
        self.assertIn("stemPadSec", player)
        self.assertIn("mashupHardCut", player)
        # Automix/Duet always hard-cut at LAND — never seamless-swap a stalled idle stream.
        self.assertIn("let mashupHardCut = isMashupTransitionMode", player)
        self.assertNotIn(
            "isMashupTransitionMode && (usedBake || !incomingIsStream)",
            player,
        )
        self.assertIn("LAND hard-cut", player)
        self.assertIn("materializeLocalAudio", player)
        self.assertIn("handoffLocalPlayback", player)
        self.assertIn("suppressTrackFinishUntil", player)
        self.assertIn("Ignoring track-finish during LAND handoff window", player)
        self.assertIn("bake.fail", player)
        self.assertIn("land.recover", player)
        self.assertIn("streamFrozen", player)
        self.assertIn("Seek first, then play", player)

        baker = (
            ROOT / "Packages/AutoMixV2/Sources/AudioEngineCore/MidSideStemBaker.swift"
        ).read_text()
        self.assertIn("bakeDuetMaster", baker)
        self.assertIn("bakeDuetStemPair", baker)
        self.assertIn("bakeAutomixStemPair", baker)
        self.assertIn("padSec", baker)
        self.assertIn("useDuetVolumes", baker)
        self.assertIn("outgoingMode: .vocal", baker)
        self.assertIn("incomingMode: .dry", baker)
        self.assertIn("incomingMode: .instrumental", baker)
        self.assertIn("A vocal isolate over B instrumental", baker)
        # Streamed mp3/aac must not use processingFormat.settings for CAF writes.
        self.assertIn("linearPCMCAFSettings", baker)
        self.assertIn("kAudioFormatLinearPCM", baker)
        # AVAudioFormat has isInterleaved, not isNonInterleaved (CI build break).
        self.assertIn("AVLinearPCMIsNonInterleaved: !format.isInterleaved", baker)
        self.assertNotIn("format.isNonInterleaved", baker)
        # 4-arg forWriting is required on device (settings-only → GenericObjCError 0).
        self.assertIn("openLinearPCMCAFWriter", baker)
        self.assertIn("commonFormat: format.commonFormat", baker)
        self.assertIn("interleaved: format.isInterleaved", baker)
        # Read m4a/mp3 as float32 non-interleaved (no AVAudioConverter capture issues).
        self.assertIn("commonFormat: .pcmFormatFloat32", baker)
        self.assertIn("interleaved: false", baker)
        self.assertNotIn(
            "AVAudioFile(forWriting: outURL, settings: format.settings)",
            baker,
        )

        player = (ROOT / "Sonivo/playercore.swift").read_text()
        self.assertIn("mashupBakeFailedUseCrossfade", player)
        self.assertIn("equal-power crossfade fallback", player)
        # After bake.fail, arm local materialized B (not hybrid stream).
        self.assertIn("localIncomingURL = inURLForBake ?? nextURL", player)
        self.assertIn("idleStreamingPlayer.volume", player)

        l10n = (ROOT / "Sonivo/SonivoL10n.swift").read_text()
        self.assertIn("LOCK", l10n)
        self.assertIn("ONE BASS", l10n)
        self.assertIn("INVITE B", l10n)
        self.assertIn("ECHO OUT", l10n)
        self.assertIn("Эхо-выход", l10n)
        self.assertIn("Мэшап", l10n)
        self.assertIn("Лок темпа", l10n)
        self.assertIn("var duet", l10n)
        self.assertIn("DUET LOCK", l10n)
        self.assertIn("DUET STACK", l10n)
        self.assertIn('"MIXING"', l10n)

        badge = (ROOT / "Sonivo/Dify/AIDJTransitionBadgeView.swift").read_text()
        self.assertIn("Mixing", badge)
        self.assertIn("Сведение", badge)

        scheduler = (
            ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupBlendScheduler.swift"
        ).read_text()
        self.assertIn("downbeatsSec.min", scheduler)
        self.assertIn("Profile mashup on grid", scheduler)

        analysis = (ROOT / "Sonivo/AutoMixV2AnalysisRuntime.swift").read_text()
        self.assertIn("transitionMode == .automix", analysis)
        self.assertIn("transitionMode == .duet", analysis)
        self.assertIn("shouldAnalyse", analysis)
        self.assertIn("allowDownload", analysis)
        self.assertIn("mixSettingsMode", analysis)

        badge_duet = (ROOT / "Sonivo/Dify/AIDJTransitionBadgeView.swift").read_text()
        self.assertIn("l10n.duet", badge_duet)

        scheduler_pref = (
            ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupBlendScheduler.swift"
        ).read_text()
        self.assertIn("defaultPreferredBlendSec: Double = 5", scheduler_pref)

    def test_session_log_does_not_reenter_playercore_during_shared_init(self):
        """Launch SIGTRAP: mode didSet → AutoMixSessionLog.snapshot → PlayerCore.shared
        while dispatch_once for PlayerCore.shared is still held."""
        player = (ROOT / "Sonivo/playercore.swift").read_text()
        self.assertIn("private(set) static var isSharedReady = false", player)
        self.assertIn("Self.isSharedReady = true", player)
        # Ready flag must flip after loadSettings (which assigns transitionMode).
        init_idx = player.index("private init()")
        ready_idx = player.index("Self.isSharedReady = true", init_idx)
        load_idx = player.index("loadSettings()", init_idx)
        self.assertLess(load_idx, ready_idx)

        log = (ROOT / "Sonivo/AutoMixSessionLog.swift").read_text()
        self.assertIn("playerCoreIfReady()", log)
        self.assertIn("PlayerCore.isSharedReady ? PlayerCore.shared : nil", log)
        self.assertIn("PlayerCore.isSharedReady", log)
        # Snapshot path must go through the gate, not bare PlayerCore.shared.
        self.assertNotIn("let core = PlayerCore.shared", log)
        self.assertIn("func fault(", log)
        self.assertIn("playback.frozen", log)
        self.assertIn("detectFrozenPlayback", log)
        analyzer = ROOT / "tools" / "analyze_automix_session_log.py"
        self.assertTrue(analyzer.is_file())
        self.assertIn("playback_frozen", analyzer.read_text())

    def test_mashup_bake_keeps_outgoing_track_timeline_until_land(self):
        """Field log: during MIXING pos/dispPos stayed at 0 after stem bake because
        CAF playhead starts at t=0. Chrome must keep track A clock until LAND."""
        player = (ROOT / "Sonivo/playercore.swift").read_text()
        self.assertIn("mashupBakeOutgoingBaseCue", player)
        self.assertIn("mashupBakeOutgoingBaseCue = cueA + bakeLag", player)
        self.assertIn("mashupBakeOutgoingBaseCue + elapsed", player)
        self.assertIn("Remount the chrome/playhead clock onto track A", player)
        self.assertIn("self.startTimer()", player)
        # playbackProgress must prefer bake outgoing clock over liveProgress/stem t=0.
        prog = player.index("var playbackProgress: Double")
        bake_clock = player.index("mashupBakeOutgoingBaseCue + elapsed", prog)
        live = player.index("liveProgress()", prog)
        self.assertLess(bake_clock, live)

    def test_drop_swap_plan_still_encodes_mashup_fx(self):
        planner = (ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift").read_text()
        self.assertIn("case .seamlessLoop", planner)
        self.assertIn("kind: .bassKill", planner)
        self.assertIn("kind: .vocalDucking", planner)
        self.assertIn("kind: .echoOut", planner)
        self.assertIn("kind: .instrumentalize", planner)
        self.assertIn("oneVocalConflict", planner)

        models = (ROOT / "Packages/AutoMixV2/Sources/MixModels/TransitionModels.swift").read_text()
        self.assertIn("case instrumentalize", models)

        deck = (ROOT / "Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift").read_text()
        self.assertIn("case .instrumentalize", deck)
        self.assertIn("applyInstrumentalize", deck)
        self.assertIn("numberOfBands: 6", deck)

        executor = (ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupTransitionExecutor.swift").read_text()
        self.assertIn(".instrumentalize", executor)

    def test_docs_describe_auto_duration_and_live_eq(self):
        docs = (ROOT / "docs/automix-mashup.md").read_text()
        self.assertIn("Бас от следующего", docs)
        self.assertIn("Мэшап-слой", docs)
        self.assertIn("BPM / такт", docs)
        self.assertIn("MashupLiveStyle", docs)
        self.assertIn("под каждую пару", docs)
        self.assertIn("MashupLiveEQEnvelope", docs)
        self.assertIn("force-disabled", docs)


if __name__ == "__main__":
    unittest.main()
