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
import {
  planTransitionType,
  transitionTypeLabel,
  type TransitionType,
} from "./transitionPlanner";

export type AIMixPlan = {
  params: MashupParams;
  profileA: TrackAIProfile;
  profileB: TrackAIProfile;
  reason: string;
  story: string;
  archetype: MashupParams["archetype"];
  transitionType: TransitionType;
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

  // --- Filters / echo by TZ transition type (via archetype) ---
  switch (params.archetype) {
    case "energyWash": // Filter Sweep
      dsp.lpfBPeak = 0.95;
      dsp.hpfAPeak = 1.0;
      dsp.echoAPeak = 0.45;
      decisions.push("FX: Filter Sweep — LPF reveal B + HPF riser A");
      break;
    case "seamlessLoop": // Long Blend
      dsp.lpfBPeak = 0.35;
      dsp.hpfAPeak = 0.55;
      dsp.echoAPeak = 0.28;
      decisions.push("FX: Long Blend — мягкие фильтры");
      break;
    case "echoOut":
      dsp.lpfBPeak = 0.4;
      dsp.hpfAPeak = 0.7;
      dsp.echoAPeak = 0.92;
      dsp.instrAPeak = Math.max(dsp.instrAPeak, 0.7);
      decisions.push("FX: Echo Out — сильный tempo-echo на A, B входит чисто");
      break;
    case "cutOnOne":
      dsp.lpfBPeak = 0.15;
      dsp.hpfAPeak = 0.35;
      dsp.echoAPeak = 0.2;
      dsp.bakeVocalB = false;
      decisions.push("FX: Cut on the 1 — короткий стык по фразе");
      break;
    case "smartCrossfade":
      dsp.lpfBPeak = 0.25;
      dsp.hpfAPeak = 0.4;
      dsp.echoAPeak = 0.2;
      dsp.instrAPeak *= 0.7;
      dsp.instrBPeak *= 0.5;
      decisions.push("FX: Smart Crossfade — мягкий fallback");
      break;
    default: // dropSwap = EQ Blend / Bass Swap
      dsp.lpfBPeak = aHasVocal && bHasVocal ? 0.75 : 0.65;
      dsp.hpfAPeak = 0.85;
      dsp.echoAPeak = 0.55;
      decisions.push("FX: EQ Blend / Bass Swap — один бас + LAND echo");
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
 * Full auto plan per TZ: Analyzer → Transition Planner → DSP recipe → play.
 */
export function planAutomix(a: TrackAIProfile, b: TrackAIProfile): AIMixPlan {
  const params = defaultParams();
  const tempo = tempoMatch(a.bpm, b.bpm);

  // Tentative cues to estimate outro length for the planner.
  const bpmGrid0 = tempo?.targetBPM || a.bpm || 120;
  const barSec0 = 240 / Math.max(60, bpmGrid0);
  const tentativeCueA = Math.min(
    Math.max(0, a.durationSec - Math.max(16, barSec0 * 8)),
    Math.max(a.durationSec * 0.7, a.mixOutSec)
  );
  const availableOutro0 = Math.max(8, a.durationSec - tentativeCueA);

  const decision = planTransitionType(a, b, availableOutro0);
  const archetype = decision.archetype;
  params.archetype = archetype;

  // Beatmatch only when planner says it's viable (or soft match within 16%).
  const beatmatched = decision.beatmatch && tempo != null;
  if (beatmatched && tempo) {
    params.rateA = tempo.rateA;
    params.rateB = tempo.rateB;
    params.targetBPM = tempo.targetBPM;
  } else if (decision.type === "cutOnOne" || decision.type === "echoOut") {
    // Keep native tempos — don't force a stretch when keys/BPM fight.
    params.rateA = 1;
    params.rateB = 1;
    params.targetBPM = a.bpm > 30 ? a.bpm : 0;
  } else if (tempo) {
    params.rateA = tempo.rateA;
    params.rateB = tempo.rateB;
    params.targetBPM = tempo.targetBPM;
  } else {
    params.rateA = 1;
    params.rateB = 1;
    params.targetBPM = a.bpm > 30 ? a.bpm : 0;
  }

  // Camelot pitch compensation (±200¢) when harmonically viable but not natural.
  params.pitchCentsB = decision.harmonic.isHarmonicallyViable
    ? Math.max(-200, Math.min(200, decision.harmonic.pitchShiftCents))
    : 0;

  const bpmGrid = params.targetBPM || a.bpm || 120;
  const barSec = 240 / Math.max(60, bpmGrid);

  let cueA = snapToBar(a.mixOutSec, a.bpm || bpmGrid);
  let cueB = snapMixIn(b.mixInSec, b.bpm || bpmGrid);

  const minOutroSec =
    decision.type === "cutOnOne"
      ? Math.max(4, barSec * 2)
      : decision.type === "echoOut"
        ? Math.max(8, barSec * 4)
        : Math.max(16, barSec * 8);
  const latestCueA = Math.max(0, a.durationSec - minOutroSec);
  const earliestCueA = Math.min(latestCueA, a.durationSec * 0.7);
  cueA = Math.min(latestCueA, Math.max(earliestCueA, cueA));
  cueA = snapToBar(cueA, a.bpm || bpmGrid);
  if (cueA > latestCueA) cueA = Math.max(0, latestCueA - (latestCueA % Math.max(barSec, 0.001)));

  const maxCueB = Math.max(barSec * 2, Math.min(b.durationSec * 0.28, 48));
  if (b.mixInSec > 0.5 && cueB < 0.5) cueB = snapMixIn(b.mixInSec, b.bpm || bpmGrid);
  cueB = Math.min(Math.max(0, cueB), maxCueB);

  const availableOutro = Math.max(minOutroSec, a.durationSec - cueA);
  const bars = phraseBars(availableOutro, barSec, archetype);
  let blend = Math.min(36, Math.max(minOutroSec, Math.min(bars * barSec, availableOutro)));
  if (decision.type === "cutOnOne") blend = Math.min(blend, Math.max(barSec * 2, 4));
  if (decision.type === "echoOut") blend = Math.min(blend, Math.max(barSec * 4, 8));
  if (decision.type === "longBlend") blend = Math.max(blend, Math.min(availableOutro, barSec * 16));
  // TZ §5: incompatible keys → avoid long blend
  if (!decision.harmonic.isHarmonicallyViable) {
    blend = Math.min(blend, Math.max(barSec * 4, 10));
  } else if (!decision.harmonic.isNaturallyCompatible) {
    blend = Math.min(blend, Math.max(barSec * 8, 16));
  }
  params.blendDurationSec = blend;
  params.cueASec = cueA;
  params.cueBSec = cueB;

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
    case "echoOut":
      params.bassSwapAt = 0.35;
      params.handoffAt = 0.62;
      params.outgoingVolumeHold = 0.28;
      params.incomingVolumeLag = 0.08;
      params.bassDepth = 1.2;
      break;
    case "cutOnOne":
      params.bassSwapAt = 0.45;
      params.handoffAt = 0.55;
      params.outgoingVolumeHold = 0.2;
      params.incomingVolumeLag = 0.02;
      params.bassDepth = 1.0;
      break;
    case "smartCrossfade":
      params.bassSwapAt = 0.4;
      params.handoffAt = 0.55;
      params.outgoingVolumeHold = 0.4;
      params.incomingVolumeLag = 0.12;
      params.bassDepth = 0.85;
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

  if (energyIn > energyOut + 0.12 && decision.type !== "cutOnOne") {
    params.bassSwapAt = Math.max(0.12, params.bassSwapAt - 0.05);
    params.handoffAt = Math.max(params.bassSwapAt + 0.18, params.handoffAt - 0.04);
  }

  if (a.hasFadeOut || a.endsInSilence) {
    params.outgoingVolumeHold = Math.max(0.2, params.outgoingVolumeHold - 0.1);
    params.blendDurationSec = Math.min(params.blendDurationSec, Math.max(8, availableOutro));
  }

  params.dsp = buildDspRecipe(a, b, params, vocalOut, vocalIn, energyOut, energyIn);

  if (params.dsp.instrBPeak >= 0.5) {
    params.handoffAt = Math.max(params.handoffAt, params.dsp.instrBUntil + 0.06);
    params.handoffAt = Math.min(0.72, params.handoffAt);
  }

  const story = [
    transitionTypeLabel(decision.type),
    vocalOut < 0.42 ? "INVITE B vocal" : "INVITE B drums",
    decision.type === "cutOnOne" ? "CUT" : "ONE BASS",
    decision.type === "echoOut" ? "ECHO→LAND" : "MASHUP→LAND",
  ].join(" → ");

  const processing = [
    `TZ type: ${transitionTypeLabel(decision.type)} · ${decision.reason}`,
    `Key A ${a.camelotKey ?? "?"} → B ${b.camelotKey ?? "?"} · ${decision.harmonic.description}`,
    beatmatched
      ? `beatmatch → ${Math.round(params.targetBPM)} BPM (A×${params.rateA.toFixed(3)} B×${params.rateB.toFixed(3)})`
      : `no forced beatmatch · rates A×${params.rateA.toFixed(3)} B×${params.rateB.toFixed(3)}`,
    params.pitchCentsB
      ? `Camelot pitch B ${params.pitchCentsB >= 0 ? "+" : ""}${params.pitchCentsB | 0}¢`
      : null,
    `cues A@${cueA.toFixed(1)}s → B@${cueB.toFixed(1)}s · ${bars | 0} bars · ${params.blendDurationSec.toFixed(1)}s`,
    `vocalOut ${(vocalOut * 100) | 0}% / vocalIn ${(vocalIn * 100) | 0}%`,
    ...params.dsp.decisions,
  ].filter(Boolean) as string[];

  return {
    params,
    profileA: a,
    profileB: b,
    reason: processing.slice(0, 2).join(" · "),
    story,
    archetype,
    transitionType: decision.type,
    beatmatched,
    processing,
  };
}
