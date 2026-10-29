/**
 * AI Automix planner — mirrors Sonivo MixPlanner + MashupLiveStyle.resolve
 * for the lab: given two analysed profiles, pick cues, rates, envelopes.
 */

import type { TrackAIProfile } from "./analyzeTrack";
import { defaultParams, tempoMatch, type MashupParams } from "./envelopes";

export type AIMixPlan = {
  params: MashupParams;
  profileA: TrackAIProfile;
  profileB: TrackAIProfile;
  reason: string;
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
  if (!matched || bpmDiff > 0.15) {
    return a.bpmConfidence >= 0.55 && b.bpmConfidence >= 0.55 ? "energyWash" : "energyWash";
  }
  if (
    a.tempoStability >= 0.75 &&
    b.tempoStability >= 0.75 &&
    bpmDiff <= 0.02
  ) {
    return "seamlessLoop";
  }
  return "dropSwap";
}

function snapToBar(sec: number, bpm: number): number {
  if (!(bpm > 30)) return sec;
  const bar = (60 / bpm) * 4;
  return Math.round(sec / bar) * bar;
}

/**
 * Build a full mashup plan like Apple Automix: analyse-driven cues,
 * beatmatch rates, bass-from-B envelopes, dual-layer volumes.
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

  // Cues on the grid (Apple: leave song body, enter B past intro).
  const bpmGrid = tempo?.targetBPM || a.bpm || 120;
  let cueA = a.mixOutSec;
  let cueB = b.mixInSec;
  cueA = snapToBar(cueA, a.bpm || bpmGrid);
  cueB = snapToBar(cueB, b.bpm || bpmGrid);
  cueA = Math.min(Math.max(a.durationSec * 0.75, cueA), Math.max(0, a.durationSec - 6));
  cueB = Math.min(Math.max(0, cueB), Math.max(0, b.durationSec * 0.25));

  const availableOutro = Math.max(4, a.durationSec - cueA);
  const barSec = 240 / Math.max(60, bpmGrid);
  const ladder =
    availableOutro >= barSec * 14
      ? barSec * 16
      : availableOutro >= barSec * 7
        ? barSec * 8
        : availableOutro;
  params.blendDurationSec = Math.min(32, Math.max(8, Math.min(ladder, availableOutro)));
  params.cueASec = cueA;
  params.cueBSec = cueB;

  // Envelope shape by archetype + vocal profiles (bass from B, mashup layer).
  switch (archetype) {
    case "seamlessLoop":
      params.bassSwapAt = 0.38;
      params.handoffAt = 0.52;
      params.outgoingVolumeHold = 0.5;
      params.incomingVolumeLag = 0.08;
      params.bassDepth = 1.05;
      break;
    case "energyWash":
      params.bassSwapAt = 0.28;
      params.handoffAt = 0.5;
      params.outgoingVolumeHold = 0.36;
      params.incomingVolumeLag = 0.05;
      params.bassDepth = 1.0;
      break;
    default:
      params.bassSwapAt = 0.22;
      params.handoffAt = 0.52;
      params.outgoingVolumeHold = 0.48;
      params.incomingVolumeLag = 0.06;
      params.bassDepth = 1.4;
  }

  const vocalOut = meanTail(a.vocalPresence);
  const vocalIn = meanHead(b.vocalPresence);
  if (vocalOut < 0.45) {
    // A outro already instrumental — hold longer under B.
    params.outgoingVolumeHold = Math.min(0.68, params.outgoingVolumeHold + 0.08);
  } else {
    params.outgoingVolumeHold = Math.max(0.32, params.outgoingVolumeHold - 0.04);
  }
  if (vocalIn > 0.5) {
    // B already has vocals — bring them in fast (Apple mashup layer).
    params.incomingVolumeLag = Math.max(0.03, params.incomingVolumeLag * 0.55);
  }
  if (a.hasFadeOut || a.endsInSilence) {
    params.outgoingVolumeHold = Math.max(0.22, params.outgoingVolumeHold - 0.08);
    params.bassDepth *= 0.9;
  }

  // Soft Camelot substitute: if BPMs close, tiny pitch nudge unused (0).
  // Real Camelot lives in iOS TrackProfile; lab keeps pitch at 0 unless user sets it.
  params.pitchCentsB = 0;

  const reason = [
    beatmatched
      ? `AI beatmatch ${Math.round(params.targetBPM)} BPM · ${a.bpm}→${b.bpm}`
      : `AI без безопасного tempo match · ${archetype}`,
    archetype,
    `A@${cueA.toFixed(1)}s → B@${cueB.toFixed(1)}s`,
    `${params.blendDurationSec.toFixed(0)}s окно`,
    `bass@${params.bassSwapAt.toFixed(2)} handoff@${params.handoffAt.toFixed(2)}`,
  ].join(" · ");

  return {
    params,
    profileA: a,
    profileB: b,
    reason,
    archetype,
    beatmatched,
  };
}
