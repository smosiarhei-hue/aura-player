/**
 * AI Automix planner — DJ “wow” grammar + Sonivo MashupLiveStyle intent.
 *
 * See `djCraft.ts` for the 5-act story. This file picks cues, phrase length,
 * rates and envelopes so the mix feels intentional — not a crossfade.
 */

import type { TrackAIProfile } from "./analyzeTrack";
import { defaultParams, tempoMatch, type MashupParams } from "./envelopes";

export type AIMixPlan = {
  params: MashupParams;
  profileA: TrackAIProfile;
  profileB: TrackAIProfile;
  reason: string;
  story: string;
  archetype: MashupParams["archetype"];
  beatmatched: boolean;
};

function meanTail(values: number[], fromFrac = 0.7): number {
  if (!values.length) return 0.5;
  const start = Math.floor(values.length * fromFrac);
  let s = 0;
  let n = 0;
  for (let i = start; i < values.length; i++) {
    s += values[i]!;
    n++;
  }
  return n ? s / n : 0.5;
}

function meanHead(values: number[], toFrac = 0.25): number {
  if (!values.length) return 0.45;
  const end = Math.max(1, Math.floor(values.length * toFrac));
  let s = 0;
  for (let i = 0; i < end; i++) s += values[i]!;
  return s / end;
}

function pickArchetype(
  a: TrackAIProfile,
  b: TrackAIProfile,
  matched: boolean,
  bpmDiff: number
): MashupParams["archetype"] {
  // Far tempos / weak grid → wash (filter story), not forced beatmatch mashup.
  if (!matched || bpmDiff > 0.12) return "energyWash";
  // Same pocket, rock-solid grid → long seamless phrase blend.
  if (a.tempoStability >= 0.75 && b.tempoStability >= 0.75 && bpmDiff <= 0.02) {
    return "seamlessLoop";
  }
  // Default wow path: bass swap + mashup peak into B’s groove.
  return "dropSwap";
}

function snapToBar(sec: number, bpm: number): number {
  if (!(bpm > 30)) return sec;
  const bar = (60 / bpm) * 4;
  return Math.round(sec / bar) * bar;
}

function phraseBars(availableOutro: number, barSec: number, archetype: MashupParams["archetype"]): number {
  // DJs think in 8 / 16 bar phrases — that’s what feels “on purpose”.
  if (archetype === "seamlessLoop" && availableOutro >= barSec * 14) return 16;
  if (availableOutro >= barSec * 14) return 16;
  if (availableOutro >= barSec * 7) return 8;
  if (availableOutro >= barSec * 3.5) return 4;
  return Math.max(2, availableOutro / barSec);
}

/**
 * Build a wow mashup plan: phrase-locked cues, one bass, vocal focus, remix peak.
 */
export function planAutomix(a: TrackAIProfile, b: TrackAIProfile): AIMixPlan {
  const params = defaultParams();
  const tempo = tempoMatch(a.bpm, b.bpm);
  const bpmDiff =
    a.bpm > 30 && b.bpm > 30 ? Math.abs(a.bpm - b.bpm) / Math.max(a.bpm, 1) : 1;

  const beatmatched = tempo != null;
  const archetype = pickArchetype(a, b, beatmatched, bpmDiff);
  params.archetype = archetype;

  if (tempo) {
    params.rateA = tempo.rateA;
    params.rateB = tempo.rateB;
    params.targetBPM = tempo.targetBPM;
  } else {
    params.rateA = 1;
    params.rateB = 1;
    params.targetBPM = a.bpm > 30 ? a.bpm : 0;
  }

  const bpmGrid = tempo?.targetBPM || a.bpm || 120;
  const barSec = 240 / Math.max(60, bpmGrid);

  // --- Cues: where a DJ would put the faders ---
  let cueA = snapToBar(a.mixOutSec, a.bpm || bpmGrid);
  let cueB = snapToBar(b.mixInSec, b.bpm || bpmGrid);
  // Never cut the song body early; leave a musical tail.
  cueA = Math.min(Math.max(a.durationSec * 0.75, cueA), Math.max(0, a.durationSec - barSec * 4));
  cueB = Math.min(Math.max(0, cueB), Math.max(0, b.durationSec * 0.28));

  const availableOutro = Math.max(barSec * 4, a.durationSec - cueA);
  const bars = phraseBars(availableOutro, barSec, archetype);
  params.blendDurationSec = Math.min(36, Math.max(barSec * 4, Math.min(bars * barSec, availableOutro)));
  params.cueASec = cueA;
  params.cueBSec = cueB;

  const vocalOut = meanTail(a.vocalPresence); // A outro still singing?
  const vocalIn = meanHead(b.vocalPresence); // B already has lead vocal?
  const energyOut = meanTail(a.energy);
  const energyIn = meanHead(b.energy);

  // --- Envelope story by archetype (wow path = dropSwap) ---
  switch (archetype) {
    case "seamlessLoop":
      // Soft invite, later bass trade, long co-existence.
      params.bassSwapAt = 0.36;
      params.handoffAt = 0.55;
      params.outgoingVolumeHold = 0.52;
      params.incomingVolumeLag = 0.1;
      params.bassDepth = 1.05;
      break;
    case "energyWash":
      // Filter drama when tempo/key aren’t friendly.
      params.bassSwapAt = 0.3;
      params.handoffAt = 0.5;
      params.outgoingVolumeHold = 0.34;
      params.incomingVolumeLag = 0.05;
      params.bassDepth = 1.05;
      break;
    default:
      // Classic wow: early ONE BASS, mid MASHUP PEAK, clean LAND.
      params.bassSwapAt = 0.2;
      params.handoffAt = 0.5;
      params.outgoingVolumeHold = 0.46;
      params.incomingVolumeLag = 0.05;
      params.bassDepth = 1.45;
  }

  // Vocal choreography — the difference between mashup and mess.
  if (vocalOut < 0.42) {
    // A is already instrumental outro → invite B vocal early (Apple mashup feel).
    params.incomingVolumeLag = Math.max(0.02, params.incomingVolumeLag * 0.45);
    params.outgoingVolumeHold = Math.min(0.7, params.outgoingVolumeHold + 0.1);
    params.bassSwapAt = Math.max(0.14, params.bassSwapAt - 0.04);
  } else {
    // A still singing → delay B’s dominance; carve space before mashup peak.
    params.outgoingVolumeHold = Math.max(0.28, params.outgoingVolumeHold - 0.06);
    params.incomingVolumeLag = Math.min(0.18, params.incomingVolumeLag + 0.04);
    params.handoffAt = Math.min(0.62, params.handoffAt + 0.04);
  }

  if (vocalIn > 0.55 && vocalOut < 0.45) {
    // Ideal Apple case: instrumental A × vocal B together.
    params.incomingVolumeLag = 0.03;
    params.bassDepth = Math.min(1.55, params.bassDepth + 0.1);
  }

  // Energy: if B hits harder, hand bass earlier so the drop feels owned by B.
  if (energyIn > energyOut + 0.12) {
    params.bassSwapAt = Math.max(0.12, params.bassSwapAt - 0.05);
    params.handoffAt = Math.max(params.bassSwapAt + 0.18, params.handoffAt - 0.04);
  }

  if (a.hasFadeOut || a.endsInSilence) {
    params.outgoingVolumeHold = Math.max(0.2, params.outgoingVolumeHold - 0.1);
    params.blendDurationSec = Math.min(params.blendDurationSec, Math.max(8, availableOutro));
  }

  params.pitchCentsB = 0;

  const story = [
    "LOCK сетка",
    vocalOut < 0.42 ? "INVITE B vocal early" : "INVITE B under A vocal",
    "ONE BASS → B",
    "MASHUP peak",
    "LAND на B",
  ].join(" → ");

  const reason = [
    beatmatched
      ? `wow beatmatch ${Math.round(params.targetBPM)} BPM`
      : `wow ${archetype} (tempo soft)`,
    `${bars | 0} bars`,
    `A@${cueA.toFixed(1)}→B@${cueB.toFixed(1)}`,
    story,
  ].join(" · ");

  return {
    params,
    profileA: a,
    profileB: b,
    reason,
    story,
    archetype,
    beatmatched,
  };
}
