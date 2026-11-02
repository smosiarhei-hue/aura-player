/**
 * Mix Critic — OpenSonic/DeckGhost-style preflight gates for a mashup plan.
 *
 * Before Play we estimate:
 *   - dual lead-vocal overlap (beats + fraction of the blend)
 *   - dual-bass ownership clash in the middle of the window
 *   - harmonic / tempo viability already chosen by TZ planner
 *
 * If vocal clash is too hot → Vocal Safe (carve A earlier, hold B instr longer).
 * If bass clash is hot → Bass Surgeon (earlier bass swap, deeper kill).
 *
 * Inspired by opensonic/mashup/verify.py + DeckGhost Performance Lab modes.
 * No Demucs required — uses measured vocalPresence + the DSP recipe envelopes.
 */

import { stemFxAt } from "../dsp/stemEnvelopes";
import type { MashupParams } from "./envelopes";
import type { TransitionType } from "./transitionPlanner";

/**
 * Budgets: OpenSonic stem clash is ~1 beat; preset harmonize allows up to 12.
 * Live Mid/Side mashup sits in between — allow a short LAND bloom, reject stacking.
 */
export const VOCAL_CLASH_MAX_BEATS = 4.0;
export const VOCAL_CLASH_MAX_FRAC = 0.18;
export const BASS_CLASH_MAX_FRAC = 0.22;
const LEAD_ON = 0.25;
const BASS_ON = 0.35;
const STEPS = 64;

export type MixCriticGate = {
  id: "vocalClash" | "bassClash" | "harmonic" | "tempo";
  ok: boolean;
  label: string;
  detail: string;
};

export type MixCriticReport = {
  ok: boolean;
  score: number;
  gates: MixCriticGate[];
  vocalClashBeats: number;
  vocalClashFrac: number;
  bassClashFrac: number;
  fixes: string[];
  mode: "pass" | "vocalSafe" | "bassSurgeon" | "vocalSafe+bassSurgeon";
};

export type MixCriticInput = {
  params: MashupParams;
  vocalOut: number;
  vocalIn: number;
  bpm: number;
  transitionType: TransitionType;
  harmonicOk: boolean;
  beatmatched: boolean;
};

function clamp01(x: number): number {
  return Math.min(1, Math.max(0, x));
}

/**
 * Estimate lead audibility after Mid/Side instrumentalize + live stem FX.
 * High instrumental amount ⇒ lead collapses; residual floor keeps realism.
 */
function leadA(vocalOut: number, instrA: number): number {
  return clamp01(vocalOut * (1 - instrA * 0.92) + vocalOut * 0.04 * (1 - instrA));
}

function leadB(vocalIn: number, instrB: number, vocalFocus: number): number {
  // While B is instrumentalized, lead is gated. After release, dry B returns.
  const gated = vocalIn * (1 - instrB);
  const opened = vocalIn * Math.max(vocalFocus, 1 - instrB);
  return clamp01(instrB > 0.08 ? gated * 0.35 : opened);
}

function bassA(bassDepth: number, killA: number): number {
  // killA from envelope: 0 = full bass, 1 = killed
  return clamp01(1 - killA * Math.min(1.2, bassDepth));
}

function bassB(bassDepth: number, restoreB: number): number {
  return clamp01(restoreB * Math.min(1.2, bassDepth));
}

/**
 * Approximate ONE BASS kill/restore from progress (mirrors envelopes.bassEqAt intent).
 */
function bassOwnership(p: number, bassAt: number): { killA: number; restoreB: number } {
  const at = Math.min(0.7, Math.max(0.08, bassAt));
  const killA = p <= 0 ? 0 : p < at ? clamp01(p / at) : 1;
  const restoreB = p <= 0 ? 0 : p < at ? clamp01(p / at) : 1;
  return { killA, restoreB };
}

export function critiqueMix(input: MixCriticInput): MixCriticReport {
  const { params, vocalOut, vocalIn, bpm, transitionType, harmonicOk, beatmatched } = input;
  const blendSec = Math.max(1, params.blendDurationSec);
  const spb = 60 / Math.max(60, bpm); // seconds per beat
  const blendBeats = blendSec / spb;

  let vocalBoth = 0;
  let bassBoth = 0;
  for (let i = 0; i < STEPS; i++) {
    const p = (i + 0.5) / STEPS;
    const fx = stemFxAt(p, params);
    const aLead = leadA(vocalOut, fx.instrumentalA);
    const bLead = leadB(vocalIn, fx.instrumentalB, fx.vocalB);
    if (aLead > LEAD_ON && bLead > LEAD_ON) vocalBoth++;

    const own = bassOwnership(p, params.bassSwapAt);
    const aBass = bassA(params.bassDepth, own.killA);
    const bBass = bassB(params.bassDepth, own.restoreB);
    // Mid-window only — invite + land naturally share less ownership conflict.
    if (p > 0.15 && p < 0.85 && aBass > BASS_ON && bBass > BASS_ON) bassBoth++;
  }

  const vocalClashFrac = vocalBoth / STEPS;
  const bassClashFrac = bassBoth / STEPS;
  const vocalClashBeats = vocalClashFrac * blendBeats;

  const vocalOk =
    vocalClashBeats <= VOCAL_CLASH_MAX_BEATS && vocalClashFrac <= VOCAL_CLASH_MAX_FRAC;
  const bassOk = bassClashFrac <= BASS_CLASH_MAX_FRAC;
  // Echo/cut intentionally tolerate key clash — gate softens there.
  const harmOk =
    harmonicOk || transitionType === "echoOut" || transitionType === "cutOnOne";
  const tempoOk = beatmatched || transitionType === "cutOnOne" || transitionType === "echoOut";

  const gates: MixCriticGate[] = [
    {
      id: "vocalClash",
      ok: vocalOk,
      label: "ONE VOCAL",
      detail: vocalOk
        ? `dual lead ${vocalClashBeats.toFixed(1)} beat · ${(vocalClashFrac * 100) | 0}%`
        : `dual lead ${vocalClashBeats.toFixed(1)} beat · ${(vocalClashFrac * 100) | 0}% (budget ${VOCAL_CLASH_MAX_BEATS} beat / ${(VOCAL_CLASH_MAX_FRAC * 100) | 0}%)`,
    },
    {
      id: "bassClash",
      ok: bassOk,
      label: "ONE BASS",
      detail: bassOk
        ? `overlap ${(bassClashFrac * 100) | 0}%`
        : `overlap ${(bassClashFrac * 100) | 0}% (budget ${(BASS_CLASH_MAX_FRAC * 100) | 0}%)`,
    },
    {
      id: "harmonic",
      ok: harmOk,
      label: "Key / Camelot",
      detail: harmOk
        ? harmonicOk
          ? "compatible or pitch-compensated"
          : `${transitionType} tolerates clash`
        : "key clash on a harmonic blend path",
    },
    {
      id: "tempo",
      ok: tempoOk,
      label: "Tempo lock",
      detail: tempoOk
        ? beatmatched
          ? "beatmatched"
          : `${transitionType} without forced stretch`
        : "BPM too far for blend",
    },
  ];

  const passed = gates.filter((g) => g.ok).length;
  const score = Math.round((passed / gates.length) * 100);
  const ok = gates.every((g) => g.ok);

  return {
    ok,
    score,
    gates,
    vocalClashBeats,
    vocalClashFrac,
    bassClashFrac,
    fixes: [],
    mode: "pass",
  };
}

/**
 * Mutate params/dsp toward Vocal Safe and/or Bass Surgeon when critic fails.
 * Returns the updated report (re-critiqued after fixes).
 */
export function applyMixCriticFixes(
  input: MixCriticInput,
  report: MixCriticReport
): MixCriticReport {
  const fixes: string[] = [];
  const needVocal = !report.gates.find((g) => g.id === "vocalClash")!.ok;
  const needBass = !report.gates.find((g) => g.id === "bassClash")!.ok;
  const dsp = input.params.dsp;

  if (needVocal) {
    // DeckGhost "Vocal Safe": carve A ASAP, keep B instrumental until A is a bed.
    dsp.instrAPeak = Math.max(dsp.instrAPeak, 0.95);
    dsp.instrAAt = Math.min(dsp.instrAAt, 0.08);
    dsp.bakeInstrA = true;
    dsp.bakeStems = true;
    if (input.vocalIn >= 0.35) {
      dsp.instrBPeak = Math.max(dsp.instrBPeak, 0.92);
      // Hold B instrumental through most of the mashup peak — only open near handoff.
      const open = Math.max(
        dsp.instrAAt + 0.28,
        Math.min(0.62, Math.max(0.42, input.params.handoffAt - 0.04))
      );
      dsp.instrBUntil = Math.max(dsp.instrBUntil, open);
      dsp.vocalBAt = Math.max(dsp.vocalBAt, open);
      dsp.vocalBPeak = Math.min(dsp.vocalBPeak, 0.55);
      dsp.bakeInstrB = true;
      input.params.handoffAt = Math.max(input.params.handoffAt, open + 0.08);
      input.params.outgoingVolumeHold = Math.min(
        input.params.outgoingVolumeHold,
        Math.max(0.18, open - 0.06)
      );
    }
    dsp.decisions = [
      ...dsp.decisions.filter((d) => !d.startsWith("Mix Critic")),
      "Mix Critic · Vocal Safe: earlier A carve + B instr gate",
    ];
    fixes.push("Vocal Safe");
  }

  if (needBass) {
    // DeckGhost "Bass Surgeon": hand bass to B earlier, dig a cleaner kill.
    input.params.bassSwapAt = Math.max(0.12, Math.min(input.params.bassSwapAt, 0.18));
    input.params.bassDepth = Math.min(1.35, Math.max(input.params.bassDepth, 1.2));
    dsp.decisions = [
      ...dsp.decisions.filter((d) => !d.startsWith("Mix Critic · Bass")),
      "Mix Critic · Bass Surgeon: earlier bass swap + deeper kill",
    ];
    fixes.push("Bass Surgeon");
  }

  const again = critiqueMix(input);
  again.fixes = fixes;
  again.mode =
    needVocal && needBass
      ? "vocalSafe+bassSurgeon"
      : needVocal
        ? "vocalSafe"
        : needBass
          ? "bassSurgeon"
          : "pass";
  return again;
}

/** Critique then auto-fix once. */
export function runMixCritic(input: MixCriticInput): MixCriticReport {
  const first = critiqueMix(input);
  if (first.ok) return first;
  return applyMixCriticFixes(input, first);
}
