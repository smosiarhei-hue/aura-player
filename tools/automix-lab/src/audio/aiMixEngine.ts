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
 * This is the “algorithm processes everything” decision layer.
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

  // --- Stem A: remove vocals when outro still sings ---
  if (vocalOut >= 0.55) {
    dsp.instrAPeak = 0.95;
    dsp.instrAAt = Math.max(0.12, params.bassSwapAt * 0.55);
    dsp.bakeStems = true;
    decisions.push("A: bake instrumental (вокал в outro → Mid/Side cut)");
  } else if (vocalOut >= 0.38) {
    dsp.instrAPeak = 0.72;
    dsp.instrAAt = Math.max(0.16, params.bassSwapAt * 0.7);
    dsp.bakeStems = true;
    decisions.push("A: soft instrumentalize (остаточный вокал)");
  } else {
    dsp.instrAPeak = 0.18; // already instrumental — barely touch
    dsp.instrAAt = 0.25;
    dsp.bakeStems = vocalIn > 0.5; // still bake B if needed
    decisions.push("A: outro уже инструментал — почти dry");
  }

  // --- Stem B: vocal focus when B has a lead ---
  if (vocalIn >= 0.55) {
    dsp.vocalBPeak = 0.88;
    dsp.vocalBAt = vocalOut < 0.42 ? 0.06 : Math.max(0.12, params.incomingVolumeLag);
    decisions.push("B: vocal focus (лид слышен в intro)");
  } else if (vocalIn >= 0.35) {
    dsp.vocalBPeak = 0.55;
    dsp.vocalBAt = 0.15;
    decisions.push("B: лёгкий vocal presence");
  } else {
    dsp.vocalBPeak = 0.2;
    dsp.vocalBAt = 0.2;
    decisions.push("B: instrumental bed — без сильного vocalize");
  }

  // Two lead vocals fighting → duck B hard until A is instrumentalized
  if (vocalOut >= 0.5 && vocalIn >= 0.5) {
    dsp.vocalDuckBDb = -9;
    dsp.vocalBAt = Math.max(dsp.vocalBAt, params.bassSwapAt * 0.9);
    dsp.instrAPeak = Math.max(dsp.instrAPeak, 0.92);
    dsp.bakeStems = true;
    decisions.push("Конфликт вокалов → duck B + жёсткий instrumental A");
  } else if (vocalOut < 0.42 && vocalIn > 0.5) {
    // Ideal Apple case
    dsp.vocalDuckBDb = -2;
    dsp.vocalBAt = 0.04;
    decisions.push("Идеал: instrumental A × vocal B сразу");
  } else {
    dsp.vocalDuckBDb = -5;
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
      dsp.lpfBPeak = 0.65;
      dsp.hpfAPeak = 0.85;
      dsp.echoAPeak = 0.55;
      decisions.push("FX: dropSwap — bass swap + echo-out на LAND");
  }

  // Energy asymmetry: harder drop into B → more drama
  if (energyIn > energyOut + 0.12) {
    dsp.hpfAPeak = Math.min(1, dsp.hpfAPeak + 0.1);
    dsp.echoAPeak = Math.min(0.85, dsp.echoAPeak + 0.1);
    decisions.push("B энергичнее → раньше отдаём пол + ярче LAND");
  }

  if (a.hasFadeOut || a.endsInSilence) {
    dsp.echoAPeak *= 0.45;
    dsp.hpfAPeak = Math.min(dsp.hpfAPeak, 0.55);
    decisions.push("A уже fade/silence → меньше echo/HPF");
  }

  dsp.bakeStems = dsp.bakeStems || dsp.instrAPeak >= 0.55 || dsp.vocalBPeak >= 0.55;
  if (dsp.bakeStems) {
    decisions.push("Offline bake стемов перед play");
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

  const story = [
    "LOCK",
    vocalOut < 0.42 ? "INVITE B vocal" : "INVITE + carve A vocal",
    "ONE BASS",
    "MASHUP",
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
