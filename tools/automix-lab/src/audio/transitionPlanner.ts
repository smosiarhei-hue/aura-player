/**
 * Transition Planner — TZ §2.4
 *
 * If BPM diff > 8% AND keys incompatible → Echo Out or Cut
 * If keys compatible + BPM close → EQ Blend / Long Blend
 * If high energy shift → Filter Sweep
 * If short outro → Echo Out (Loop optional later)
 * Else → Smart Crossfade
 */

import type { TrackAIProfile } from "./analyzeTrack";
import { camelotMatch, type HarmonicMatch } from "./keyCamelot";
import type { MashupArchetype } from "./envelopes";

export type TransitionType =
  | "eqBlend"
  | "filterSweep"
  | "echoOut"
  | "longBlend"
  | "cutOnOne"
  | "smartCrossfade";

export type TransitionDecision = {
  type: TransitionType;
  /** Maps to MashupParams.archetype used by envelopes/DSP. */
  archetype: MashupArchetype;
  harmonic: HarmonicMatch;
  bpmDiff: number;
  energyShift: number;
  outroSec: number;
  reason: string;
  beatmatch: boolean;
};

const TYPE_TO_ARCHETYPE: Record<TransitionType, MashupArchetype> = {
  eqBlend: "dropSwap",
  filterSweep: "energyWash",
  echoOut: "echoOut",
  longBlend: "seamlessLoop",
  cutOnOne: "cutOnOne",
  smartCrossfade: "smartCrossfade",
};

function meanHead(values: number[], toFrac = 0.25): number {
  if (!values.length) return 0.45;
  const end = Math.max(1, Math.floor(values.length * toFrac));
  let s = 0;
  for (let i = 0; i < end; i++) s += values[i]!;
  return s / end;
}

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

/**
 * Choose transition type for a pair (TZ AutoMix Intelligent Transitions §2.4).
 */
export function planTransitionType(
  a: TrackAIProfile,
  b: TrackAIProfile,
  availableOutroSec: number
): TransitionDecision {
  const bpmDiff =
    a.bpm > 30 && b.bpm > 30 ? Math.abs(a.bpm - b.bpm) / Math.max(a.bpm, b.bpm, 1) : 1;
  const harmonic = camelotMatch(a.camelotKey, b.camelotKey);
  const energyOut = meanTail(a.energy);
  const energyIn = meanHead(b.energy);
  const energyShift = energyIn - energyOut;
  const outroSec = Math.max(0, availableOutroSec);
  const bpmClose = bpmDiff <= 0.08;
  const bpmFar = bpmDiff > 0.08;
  const bpmVeryFar = bpmDiff > 0.12;
  const beatmatch = bpmDiff <= 0.16 && a.bpm > 30 && b.bpm > 30;

  let type: TransitionType;
  let reason: string;

  // 1. Far tempo + incompatible key → Echo Out or Cut (never long harmonic blend)
  if ((bpmFar && !harmonic.isHarmonicallyViable) || (bpmVeryFar && !harmonic.isNaturallyCompatible)) {
    type = bpmVeryFar || outroSec < 12 ? "cutOnOne" : "echoOut";
    reason =
      type === "cutOnOne"
        ? `Cut on 1 · BPM Δ${(bpmDiff * 100) | 0}% · ${harmonic.description}`
        : `Echo Out · BPM Δ${(bpmDiff * 100) | 0}% · ${harmonic.description}`;
  }
  // 2. Short outro → Echo Out (Loop+Build later)
  else if (outroSec > 0 && outroSec < 14) {
    type = "echoOut";
    reason = `Echo Out · короткий outro ${outroSec.toFixed(1)}s`;
  }
  // 3. High energy shift → Filter Sweep
  else if (energyShift > 0.14 || energyShift < -0.18) {
    type = "filterSweep";
    reason = `Filter Sweep · energy Δ ${energyShift >= 0 ? "+" : ""}${(energyShift * 100) | 0}%`;
  }
  // 4. Compatible keys + close BPM → EQ Blend or Long Blend
  else if (harmonic.isNaturallyCompatible && bpmClose) {
    const stable = a.tempoStability >= 0.7 && b.tempoStability >= 0.7;
    type = stable && outroSec >= 28 ? "longBlend" : "eqBlend";
    reason =
      type === "longBlend"
        ? `Long Blend · ${harmonic.description} · BPM Δ${(bpmDiff * 100) | 0}%`
        : `EQ Blend / Bass Swap · ${harmonic.description}`;
  }
  // 5. Viable with small pitch shift + close-ish BPM → EQ Blend
  else if (harmonic.isHarmonicallyViable && bpmDiff <= 0.1) {
    type = "eqBlend";
    reason = `EQ Blend · ${harmonic.description}`;
  }
  // 6. Fallback smart crossfade
  else {
    type = bpmFar ? "echoOut" : "smartCrossfade";
    reason =
      type === "echoOut"
        ? `Echo Out fallback · BPM Δ${(bpmDiff * 100) | 0}%`
        : `Smart Crossfade · ${harmonic.description}`;
  }

  return {
    type,
    archetype: TYPE_TO_ARCHETYPE[type],
    harmonic,
    bpmDiff,
    energyShift,
    outroSec,
    reason,
    beatmatch,
  };
}

export function transitionTypeLabel(type: TransitionType): string {
  switch (type) {
    case "eqBlend":
      return "EQ Blend / Bass Swap";
    case "filterSweep":
      return "Filter Sweep";
    case "echoOut":
      return "Echo Out";
    case "longBlend":
      return "Long Blend";
    case "cutOnOne":
      return "Cut on the 1";
    case "smartCrossfade":
      return "Smart Crossfade";
  }
}
