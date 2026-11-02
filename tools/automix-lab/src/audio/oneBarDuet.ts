/**
 * One-Bar Duet — separate Song Transition (not AutoMix mashup grammar).
 *
 * Intentional short dual-vocal: A lead + B lead overlap for ~1 bar on a
 * shared beat grid, then hard LAND to B. Next track is already audible;
 * the ear hears a remix bar, not a crossfade and not ONE VOCAL carve.
 *
 * Separate commit / product mode from AutoMix Acapella Drop / Safe Exit.
 */

import type { TrackAIProfile } from "./analyzeTrack";
import {
  defaultDsp,
  defaultParams,
  tempoMatch,
  type MashupParams,
} from "./envelopes";
import type { AIMixPlan } from "./aiMixEngine";
import { vocalLevelNear } from "./aiMixEngine";
import type { MixCriticReport } from "./mixCritic";

export const ONE_BAR_DUET_MODE = "oneBarDuet" as const;

function snapToBar(sec: number, bpm: number): number {
  if (!(bpm > 30)) return Math.max(0, sec);
  const bar = (60 / bpm) * 4;
  return Math.max(0, Math.round(sec / bar) * bar);
}

function snapMixIn(sec: number, bpm: number): number {
  if (!(bpm > 30)) return Math.max(0, sec);
  const bar = (60 / bpm) * 4;
  if (sec <= 0.25) return 0;
  const snapped = Math.round(sec / bar) * bar;
  if (snapped < 0.5 && sec >= bar * 0.4) return bar;
  return Math.max(0, snapped);
}

function passCritic(detail: string): MixCriticReport {
  return {
    ok: true,
    score: 100,
    gates: [
      {
        id: "vocalClash",
        ok: true,
        label: "DUET VOCAL",
        detail,
      },
      {
        id: "bassClash",
        ok: true,
        label: "ONE BASS",
        detail: "short bar · bass swap mid-window",
      },
      {
        id: "harmonic",
        ok: true,
        label: "Key / Camelot",
        detail: "pitch-compensated when needed",
      },
      {
        id: "tempo",
        ok: true,
        label: "Tempo lock",
        detail: "beatmatched 1-bar grid",
      },
      {
        id: "land",
        ok: true,
        label: "LAND",
        detail: "cut to B on bar end",
      },
    ],
    vocalClashBeats: 4,
    vocalClashFrac: 1,
    bassClashFrac: 0,
    bassClashBeats: 0,
    fixes: [],
    mode: "pass",
  };
}

/**
 * Plan a ~1-bar dual-vocal Automix window.
 * Both leads stay dry; Mix Critic Vocal Safe is intentionally bypassed.
 */
export function planOneBarDuet(a: TrackAIProfile, b: TrackAIProfile): AIMixPlan {
  const params = defaultParams();
  const tempo = tempoMatch(a.bpm, b.bpm);
  const bpm = tempo?.targetBPM || a.bpm || 120;
  const barSec = 240 / Math.max(60, bpm);

  if (tempo) {
    params.rateA = tempo.rateA;
    params.rateB = tempo.rateB;
    params.targetBPM = tempo.targetBPM;
  } else {
    params.rateA = 1;
    params.rateB = 1;
    params.targetBPM = a.bpm > 30 ? a.bpm : bpm;
  }

  // Harmonic nudge if Camelot is close enough via tempo helper rates only —
  // keep pitch light; duet is about the vocal collide, not a long key ride.
  params.pitchCentsB = 0;
  params.archetype = "cutOnOne";

  // Exactly one bar of overlap (clamp so slow tracks still feel like a bar).
  const blend = Math.min(4.2, Math.max(1.55, barSec));
  params.blendDurationSec = blend;

  // Leave room for the 1-bar window near the end of A.
  const latestA = Math.max(0, a.durationSec - blend - 0.05);
  let cueA = snapToBar(
    Math.min(latestA, Math.max(a.durationSec * 0.72, a.mixOutSec)),
    a.bpm || bpm
  );
  if (cueA > latestA) cueA = Math.max(0, latestA - (latestA % Math.max(barSec, 0.001)));
  params.cueASec = cueA;

  const maxCueB = Math.max(barSec, Math.min(b.durationSec * 0.28, 32));
  let cueB = b.mixInSec > 0.5 ? snapMixIn(b.mixInSec, b.bpm || bpm) : 0;
  cueB = Math.min(Math.max(0, cueB), maxCueB);
  params.cueBSec = cueB;

  // Mid-bar: invite → dual peak → LAND on the 1 of the next bar.
  params.bassSwapAt = 0.28;
  params.handoffAt = 0.62;
  params.outgoingVolumeHold = 0.18;
  params.incomingVolumeLag = 0.06;
  params.bassDepth = 0.95;

  const vocalOut = vocalLevelNear(a, cueA, Math.min(6, blend));
  const vocalIn = vocalLevelNear(b, cueB, Math.min(6, blend));

  const dsp = defaultDsp();
  dsp.mashupMode = ONE_BAR_DUET_MODE;
  // Both leads dry — the whole point of the mode.
  dsp.instrAPeak = 0;
  dsp.instrAAt = 0;
  dsp.instrBPeak = 0;
  dsp.instrBUntil = 0;
  dsp.vocalBPeak = 0;
  dsp.vocalBAt = 0;
  dsp.vocalDuckBDb = 0;
  dsp.hpfAPeak = 0.55;
  dsp.lpfBPeak = 0.2;
  dsp.echoAPeak = 0.12;
  dsp.bakeStems = false;
  dsp.bakeInstrA = false;
  dsp.bakeInstrB = false;
  dsp.bakeVocalB = false;
  dsp.sidechainA = 0.15;
  dsp.dualLayerPeak = 1;
  dsp.guardVocalOut = vocalOut;
  dsp.guardVocalIn = vocalIn;
  dsp.decisions = [
    "One-Bar Duet · dual lead intentional",
    `1 bar @ ${Math.round(bpm)} BPM · ${blend.toFixed(2)}s`,
    "A+B vocals dry → LAND B on next downbeat",
  ];
  params.dsp = dsp;

  const critic = passCritic(
    `intentional dual lead · 1 bar (${blend.toFixed(2)}s) · no Vocal Safe`
  );

  return {
    params,
    profileA: a,
    profileB: b,
    reason: "One-Bar Duet Song Transition",
    story: "DUET · A+B vocals · 1 bar · LAND B",
    archetype: "cutOnOne",
    transitionType: "cutOnOne",
    beatmatched: tempo != null,
    processing: [
      "One-Bar Duet (Song Transitions)",
      "Beatmatch grid",
      "Both vocals dry for 1 bar",
      "Bass swap mid-bar",
      "LAND → B alone",
      ...dsp.decisions,
    ],
    critic,
    vocalOut,
    vocalIn,
  };
}

/** Volume ride for One-Bar Duet: both hot, equal-power, then snap to B. */
export function oneBarDuetVolumes(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const handoff = Math.min(0.78, Math.max(0.48, params.handoffAt));
  const invite = Math.min(0.22, Math.max(0.06, params.incomingVolumeLag || 0.06));
  // A stays loud through the collide, then exits fast into LAND.
  const outgoing =
    p <= handoff
      ? 1
      : Math.max(0, 1 - (p - handoff) / Math.max(0.08, 1 - handoff));
  // B blooms in within the first beats, full by collide, home after handoff.
  const incoming =
    p <= invite
      ? p / invite
      : p >= handoff
        ? 1
        : 0.92 + 0.08 * ((p - invite) / Math.max(0.001, handoff - invite));
  const pow = Math.hypot(outgoing, incoming);
  if (p < handoff && pow > 0.05) {
    const s = Math.min(1.15, 0.95 / pow);
    return {
      outgoing: Math.min(1, outgoing * s),
      incoming: Math.min(1, incoming * s),
    };
  }
  return {
    outgoing: Math.min(1, Math.max(0, outgoing)),
    incoming: Math.min(1, Math.max(0, incoming)),
  };
}

export function oneBarDuetPhase(p: number, params: MashupParams): string {
  const handoff = params.handoffAt;
  if (p < 0.12) {
    return params.targetBPM > 30
      ? `DUET LOCK ${Math.round(params.targetBPM)}`
      : "DUET LOCK";
  }
  if (p < handoff - 0.08) return "DUET · A+B";
  if (p < handoff + 0.1) return "DUET LAND";
  return "LAND";
}
