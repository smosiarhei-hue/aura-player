/**
 * AI Automix planner — decides the FULL processing recipe from track analysis.
 *
 * Not just volume knobs: stem bake, vocal focus, bass ownership, filter drama,
 * echo-out. The engine then executes this recipe automatically.
 */

import type { TrackAIProfile } from "./analyzeTrack";
import {
  defaultDsp,
  defaultParams,
  tempoMatch,
  type AutoDspRecipe,
  type MashupParams,
} from "./envelopes";

export type AIMixPlan = {
  params: MashupParams;
  profileA: TrackAIProfile;
  profileB: TrackAIProfile;
  reason: string;
  story: string;
  archetype: MashupParams["archetype"];
  beatmatched: boolean;
  /** What the algorithm will process — shown in UI. */
  processing: string[];
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

/** Vocal level specifically around mixOut / mixIn windows. */
function vocalNear(profile: TrackAIProfile, sec: number, windowSec = 8): number {
  const hop = 0.25;
  const i0 = Math.max(0, Math.floor((sec - windowSec * 0.25) / hop));
  const i1 = Math.min(profile.vocalPresence.length, Math.ceil((sec + windowSec * 0.75) / hop));
  if (i1 <= i0) return meanTail(profile.vocalPresence);
  let s = 0;
  for (let i = i0; i < i1; i++) s += profile.vocalPresence[i]!;
  return s / (i1 - i0);
}

function energyNear(profile: TrackAIProfile, sec: number, windowSec = 8): number {
  const hop = 0.25;
  const i0 = Math.max(0, Math.floor((sec - windowSec * 0.25) / hop));
  const i1 = Math.min(profile.energy.length, Math.ceil((sec + windowSec * 0.75) / hop));
  if (i1 <= i0) return meanTail(profile.energy);
  let s = 0;
  for (let i = i0; i < i1; i++) s += profile.energy[i]!;
  return s / (i1 - i0);
}

function pickArchetype(
  a: TrackAIProfile,
  b: TrackAIProfile,
  matched: boolean,
  bpmDiff: number
): MashupParams["archetype"] {
  if (!matched || bpmDiff > 0.12) return "energyWash";
  if (a.tempoStability >= 0.75 && b.tempoStability >= 0.75 && bpmDiff <= 0.02) {
    return "seamlessLoop";
  }
  return "dropSwap";
}

function snapToBar(sec: number, bpm: number): number {
  if (!(bpm > 30)) return sec;
  const bar = (60 / bpm) * 4;
  return Math.round(sec / bar) * bar;
}

/** Mix-in: never snap down to 0 — prefer the next bar if we're past a quiet head. */
function snapMixIn(sec: number, bpm: number): number {
  if (!(bpm > 30)) return Math.max(0, sec);
  const bar = (60 / bpm) * 4;
  if (sec <= 0.25) return 0;
  // Round to nearest bar, but keep at least 1 bar if analysis found an intro.
  const snapped = Math.round(sec / bar) * bar;
  if (snapped < 0.5 && sec >= bar * 0.4) return bar;
  return Math.max(0, snapped);
}

function phraseBars(
  availableOutro: number,
  barSec: number,
  archetype: MashupParams["archetype"]
): number {
  if (archetype === "seamlessLoop" && availableOutro >= barSec * 14) return 16;
  if (availableOutro >= barSec * 14) return 16;
  if (availableOutro >= barSec * 7) return 8;
  if (availableOutro >= barSec * 3.5) return 4;
  return Math.max(2, availableOutro / barSec);
}

/**
 * Build DSP recipe from measured vocal/energy at the actual cues.
 *
 * ONE VOCAL RULE (Apple / club mashup grammar):
 *   A instrumental × B vocal  → stack OK (the desired mashup)
 *   A vocal × B instrumental  → OK (A still leads)
 *   A vocal × B vocal         → NEVER — cut one lead before the other opens
 */
function buildDspRecipe(
  a: TrackAIProfile,
  _b: TrackAIProfile,
  params: MashupParams,
  vocalOut: number,
  vocalIn: number,
  energyOut: number,
  energyIn: number
): AutoDspRecipe {
  const dsp = defaultDsp();
  const decisions: string[] = [];
  const aHasVocal = vocalOut >= 0.42;
  const bHasVocal = vocalIn >= 0.4;

  // --- Case 1: ideal — A outro already instrumental, B has vocal ---
  if (!aHasVocal && bHasVocal) {
    dsp.instrAPeak = 0.12;
    dsp.instrAAt = 0.2;
    dsp.instrBPeak = 0;
    dsp.instrBUntil = 0.05;
    dsp.vocalBPeak = vocalIn >= 0.55 ? 0.9 : 0.7;
    dsp.vocalBAt = 0.04;
    dsp.vocalDuckBDb = -1.5;
    dsp.bakeInstrA = false;
    dsp.bakeVocalB = true;
    dsp.bakeStems = true;
    decisions.push("ONE VOCAL: A уже инструментал → вокал B сразу поверх");
  }
  // --- Case 2: conflict — both leads present ---
  else if (aHasVocal && bHasVocal) {
    // Kill A vocal fast; keep B instrumental (no B lead) until A is a bed; then open B vocal.
    dsp.instrAPeak = 0.98;
    dsp.instrAAt = Math.min(0.22, Math.max(0.08, params.bassSwapAt * 0.55));
    dsp.instrBPeak = 0.95; // remove B vocal while A still occupies the lead
    dsp.instrBUntil = Math.max(dsp.instrAAt + 0.12, params.bassSwapAt + 0.05);
    dsp.vocalBPeak = 0.88;
    dsp.vocalBAt = dsp.instrBUntil + 0.02; // only after B instrumental gate lifts
    dsp.vocalDuckBDb = -12;
    dsp.bakeInstrA = true;
    dsp.bakeVocalB = false; // CRITICAL: never bake B vocal for whole blend
    dsp.bakeStems = true;
    // Give A a bit more hold so instrumentalize finishes before handoff.
    decisions.push(
      "ONE VOCAL: конфликт → bake A instrumental, B без вокала до готовности A, потом вокал B"
    );
  }
  // --- Case 3: A still sings, B is instrumental bed ---
  else if (aHasVocal && !bHasVocal) {
    dsp.instrAPeak = 0.55; // soft carve, A may keep some presence
    dsp.instrAAt = 0.35;
    dsp.instrBPeak = 0;
    dsp.instrBUntil = 0.1;
    dsp.vocalBPeak = 0.15;
    dsp.vocalBAt = 0.5;
    dsp.vocalDuckBDb = -3;
    dsp.bakeInstrA = vocalOut >= 0.55;
    dsp.bakeVocalB = false;
    dsp.bakeStems = dsp.bakeInstrA;
    decisions.push("ONE VOCAL: вокал A × инструментал B — B без vocalize");
  }
  // --- Case 4: both instrumental-ish ---
  else {
    dsp.instrAPeak = 0.15;
    dsp.instrAAt = 0.25;
    dsp.instrBPeak = 0;
    dsp.instrBUntil = 0.1;
    dsp.vocalBPeak = 0.2;
    dsp.vocalBAt = 0.25;
    dsp.vocalDuckBDb = -2;
    dsp.bakeInstrA = false;
    dsp.bakeVocalB = false;
    dsp.bakeStems = false;
    decisions.push("Оба инструментальны — текстурный мэшап без stem bake");
  }

  // --- Filters / echo by archetype ---
  switch (params.archetype) {
    case "energyWash":
      dsp.lpfBPeak = 0.95;
      dsp.hpfAPeak = 1.0;
      dsp.echoAPeak = 0.75;
      decisions.push("FX: energyWash — сильный LPF→HPF + echo");
      break;
    case "seamlessLoop":
      dsp.lpfBPeak = 0.35;
      dsp.hpfAPeak = 0.55;
      dsp.echoAPeak = 0.28;
      decisions.push("FX: seamless — мягкие фильтры, тихий echo");
      break;
    default:
      dsp.lpfBPeak = aHasVocal && bHasVocal ? 0.75 : 0.65;
      dsp.hpfAPeak = 0.85;
      dsp.echoAPeak = 0.55;
      decisions.push("FX: dropSwap — bass swap + echo-out на LAND");
  }

  if (energyIn > energyOut + 0.12) {
    dsp.hpfAPeak = Math.min(1, dsp.hpfAPeak + 0.1);
    dsp.echoAPeak = Math.min(0.85, dsp.echoAPeak + 0.1);
    decisions.push("B энергичнее → раньше пол + ярче LAND");
  }

  if (a.hasFadeOut || a.endsInSilence) {
    dsp.echoAPeak *= 0.45;
    dsp.hpfAPeak = Math.min(dsp.hpfAPeak, 0.55);
    decisions.push("A уже fade/silence → меньше echo/HPF");
  }

  if (dsp.bakeStems) {
    decisions.push(
      `Bake: A instrumental=${dsp.bakeInstrA ? "yes" : "no"}, B vocal=${dsp.bakeVocalB ? "yes" : "no"}`
    );
  }

  dsp.decisions = decisions;
  return dsp;
}

/**
 * Full auto plan: cues + envelopes + DSP recipe the engine will execute.
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

  let cueA = snapToBar(a.mixOutSec, a.bpm || bpmGrid);
  let cueB = snapMixIn(b.mixInSec, b.bpm || bpmGrid);

  // Hard guarantee: at least 8 bars (or 16s) of A remain after cue for the mashup.
  const minOutroSec = Math.max(16, barSec * 8);
  const latestCueA = Math.max(0, a.durationSec - minOutroSec);
  const earliestCueA = Math.min(latestCueA, a.durationSec * 0.7);
  cueA = Math.min(latestCueA, Math.max(earliestCueA, cueA));
  cueA = snapToBar(cueA, a.bpm || bpmGrid);
  if (cueA > latestCueA) cueA = Math.max(0, latestCueA - (latestCueA % Math.max(barSec, 0.001)));

  // B enters after quiet intro — keep mixIn, never force 0 when analysis found a groove.
  const maxCueB = Math.max(barSec * 2, Math.min(b.durationSec * 0.28, 48));
  if (b.mixInSec > 0.5 && cueB < 0.5) cueB = snapMixIn(b.mixInSec, b.bpm || bpmGrid);
  cueB = Math.min(Math.max(0, cueB), maxCueB);

  const availableOutro = Math.max(minOutroSec, a.durationSec - cueA);
  const bars = phraseBars(availableOutro, barSec, archetype);
  params.blendDurationSec = Math.min(
    36,
    Math.max(barSec * 8, Math.min(bars * barSec, availableOutro))
  );
  params.cueASec = cueA;
  params.cueBSec = cueB;

  // Measure vocals/energy AT the cues the plan will actually use.
  const vocalOut = vocalNear(a, cueA, Math.min(12, params.blendDurationSec));
  const vocalIn = vocalNear(b, cueB, Math.min(12, params.blendDurationSec));
  const energyOut = energyNear(a, cueA, 10);
  const energyIn = energyNear(b, cueB, 10);

  switch (archetype) {
    case "seamlessLoop":
      params.bassSwapAt = 0.36;
      params.handoffAt = 0.55;
      params.outgoingVolumeHold = 0.52;
      params.incomingVolumeLag = 0.1;
      params.bassDepth = 1.05;
      break;
    case "energyWash":
      params.bassSwapAt = 0.28;
      params.handoffAt = 0.48;
      params.outgoingVolumeHold = 0.34;
      params.incomingVolumeLag = 0.05;
      params.bassDepth = 1.1;
      break;
    default:
      params.bassSwapAt = 0.2;
      params.handoffAt = 0.5;
      params.outgoingVolumeHold = 0.46;
      params.incomingVolumeLag = 0.05;
      params.bassDepth = 1.45;
  }

  if (vocalOut < 0.42) {
    params.incomingVolumeLag = Math.max(0.02, params.incomingVolumeLag * 0.45);
    params.outgoingVolumeHold = Math.min(0.7, params.outgoingVolumeHold + 0.1);
    params.bassSwapAt = Math.max(0.14, params.bassSwapAt - 0.04);
  } else {
    params.outgoingVolumeHold = Math.max(0.28, params.outgoingVolumeHold - 0.06);
    params.incomingVolumeLag = Math.min(0.18, params.incomingVolumeLag + 0.04);
    params.handoffAt = Math.min(0.62, params.handoffAt + 0.04);
  }

  if (vocalIn > 0.55 && vocalOut < 0.45) {
    params.incomingVolumeLag = 0.03;
    params.bassDepth = Math.min(1.55, params.bassDepth + 0.1);
  }

  if (energyIn > energyOut + 0.12) {
    params.bassSwapAt = Math.max(0.12, params.bassSwapAt - 0.05);
    params.handoffAt = Math.max(params.bassSwapAt + 0.18, params.handoffAt - 0.04);
  }

  if (a.hasFadeOut || a.endsInSilence) {
    params.outgoingVolumeHold = Math.max(0.2, params.outgoingVolumeHold - 0.1);
    params.blendDurationSec = Math.min(params.blendDurationSec, Math.max(8, availableOutro));
  }

  params.pitchCentsB = 0;
  params.dsp = buildDspRecipe(a, b, params, vocalOut, vocalIn, energyOut, energyIn);

  // Align handoff with one-vocal gate so MASHUP opens when B vocal is allowed.
  if (params.dsp.instrBPeak >= 0.5) {
    params.handoffAt = Math.max(params.handoffAt, params.dsp.instrBUntil + 0.06);
    params.handoffAt = Math.min(0.72, params.handoffAt);
  }

  const story = [
    "LOCK",
    vocalOut < 0.42 ? "INVITE B vocal" : "INVITE B drums (без вокала B)",
    "ONE BASS",
    vocalOut >= 0.42 && vocalIn >= 0.4 ? "MASHUP (вокал B после carve A)" : "MASHUP",
    "LAND",
  ].join(" → ");

  const processing = [
    beatmatched
      ? `beatmatch → ${Math.round(params.targetBPM)} BPM (A×${params.rateA.toFixed(3)} B×${params.rateB.toFixed(3)})`
      : `tempo soft · ${archetype}`,
    `cues A@${cueA.toFixed(1)}s → B@${cueB.toFixed(1)}s · ${bars | 0} bars`,
    `vocalOut ${(vocalOut * 100) | 0}% / vocalIn ${(vocalIn * 100) | 0}%`,
    ...params.dsp.decisions,
  ];

  const reason = processing.slice(0, 3).join(" · ");

  return {
    params,
    profileA: a,
    profileB: b,
    reason,
    story,
    archetype,
    beatmatched,
    processing,
  };
}
