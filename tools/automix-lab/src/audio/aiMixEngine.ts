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
import { chooseModernMashup } from "./modernMashup";

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
 * Modern mashup grammar (see modernMashup.ts):
 *   A instrumental bed × B vocal  → the remix bar we want
 *   Never two leads at once — but B vocal opens on mashup peak once A is carved,
 *   not only at LAND (that killed the dual-layer magic).
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
  const craft = chooseModernMashup(
    vocalOut,
    vocalIn,
    params.bassSwapAt,
    params.handoffAt
  );
  dsp.mashupMode = craft.mode;
  dsp.sidechainA = craft.sidechainA;
  decisions.push(`Mashup craft: ${craft.label} — ${craft.story}`);

  switch (craft.mode) {
    case "acapellaDrop": {
      dsp.instrAPeak = craft.bakeInstrA ? 0.55 : 0.1;
      dsp.instrAAt = craft.aInstrReadyAt;
      dsp.instrBPeak = 0;
      dsp.instrBUntil = 0.04;
      dsp.vocalBPeak = 0; // keep B dry/full quality — no live vocalize thinning
      dsp.vocalBAt = craft.bVocalOpenAt;
      dsp.vocalDuckBDb = 0;
      dsp.bakeInstrA = craft.bakeInstrA;
      dsp.bakeInstrB = false;
      dsp.bakeVocalB = false;
      dsp.bakeStems = craft.bakeInstrA;
      dsp.sidechainA = 0;
      decisions.push("Acapella Drop: A bed (если нужно) × B full quality");
      break;
    }
    case "vocalSwap": {
      // Carve A lead only; B short groove then dry at full quality.
      dsp.instrAPeak = 0.85;
      dsp.instrAAt = craft.aInstrReadyAt;
      dsp.instrBPeak = 0.75;
      dsp.instrBUntil = craft.bVocalOpenAt;
      dsp.vocalBPeak = 0; // dry B after open — don't re-thin with vocalize
      dsp.vocalBAt = craft.bVocalOpenAt;
      dsp.vocalDuckBDb = -4; // light pocket only while B still gated
      dsp.bakeInstrA = true;
      dsp.bakeInstrB = true;
      dsp.bakeVocalB = false;
      dsp.bakeStems = true;
      dsp.sidechainA = 0;
      decisions.push(
        `Vocal Swap: carve A lead + B groove→dry @ ${(craft.bVocalOpenAt * 100) | 0}% (без sidechain/muffle)`
      );
      break;
    }
    case "textureBed": {
      dsp.instrAPeak = 0.4;
      dsp.instrAAt = craft.aInstrReadyAt;
      dsp.instrBPeak = 0;
      dsp.instrBUntil = 0.1;
      dsp.vocalBPeak = 0;
      dsp.vocalBAt = 0.55;
      dsp.vocalDuckBDb = 0;
      dsp.bakeInstrA = craft.bakeInstrA;
      dsp.bakeInstrB = false;
      dsp.bakeVocalB = false;
      dsp.bakeStems = craft.bakeInstrA;
      dsp.sidechainA = 0;
      decisions.push("Texture Bed: мягкий carve A × B dry");
      break;
    }
    default: {
      dsp.instrAPeak = 0.1;
      dsp.instrAAt = 0.22;
      dsp.instrBPeak = 0;
      dsp.instrBUntil = 0.1;
      dsp.vocalBPeak = 0;
      dsp.vocalBAt = 0.28;
      dsp.vocalDuckBDb = 0;
      dsp.bakeInstrA = false;
      dsp.bakeInstrB = false;
      dsp.bakeVocalB = false;
      dsp.bakeStems = false;
      dsp.sidechainA = 0;
      decisions.push("Instrumental Wash: без stem bake / без приглушения");
    }
  }

  // Filters only where the TZ type needs drama — keep peaks modest so quality stays even.
  switch (params.archetype) {
    case "energyWash": // Filter Sweep — the one place LPF/HPF are intentional
      dsp.lpfBPeak = 0.55;
      dsp.hpfAPeak = 0.7;
      dsp.echoAPeak = 0.35;
      decisions.push("FX: Filter Sweep — мягкий LPF→reveal + HPF на LAND");
      break;
    case "seamlessLoop":
      dsp.lpfBPeak = 0.15;
      dsp.hpfAPeak = 0.4;
      dsp.echoAPeak = 0.2;
      decisions.push("FX: Long Blend — почти без фильтров");
      break;
    case "echoOut":
      dsp.lpfBPeak = 0.12;
      dsp.hpfAPeak = 0.55;
      dsp.echoAPeak = 0.85;
      decisions.push("FX: Echo Out — echo на A, B без LPF-одеяла");
      break;
    case "cutOnOne":
      dsp.lpfBPeak = 0;
      dsp.hpfAPeak = 0.25;
      dsp.echoAPeak = 0.15;
      dsp.bakeVocalB = false;
      decisions.push("FX: Cut on the 1 — без muffling");
      break;
    case "smartCrossfade":
      dsp.lpfBPeak = 0.1;
      dsp.hpfAPeak = 0.35;
      dsp.echoAPeak = 0.15;
      if (dsp.instrBPeak < 0.5) {
        dsp.instrAPeak *= 0.85;
      }
      decisions.push("FX: Smart Crossfade — мягкий fallback");
      break;
    default: // EQ Blend — bass swap owns the drama, not filters
      dsp.lpfBPeak = 0.12;
      dsp.hpfAPeak = 0.55;
      dsp.echoAPeak = 0.35;
      decisions.push("FX: EQ Blend — один бас, фильтры только на LAND");
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
      `Bake: A instr=${dsp.bakeInstrA ? "yes" : "no"}, B instr=${dsp.bakeInstrB ? "yes" : "no"}, B vocal=${dsp.bakeVocalB ? "yes" : "no"}`
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

  // Beatmatch whenever tempos are within lock range — including Echo Out on key clash.
  // Only abandon stretch when cut/echo was chosen because BPM itself is too far.
  const beatmatched = decision.beatmatch && tempo != null;
  const abandonStretch =
    !beatmatched && (decision.type === "cutOnOne" || decision.type === "echoOut");
  if (beatmatched && tempo) {
    params.rateA = tempo.rateA;
    params.rateB = tempo.rateB;
    params.targetBPM = tempo.targetBPM;
  } else if (abandonStretch) {
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
        ? Math.max(16, barSec * 8) // leave a full phrase for echo→LAND
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
  if (decision.type === "cutOnOne") {
    blend = Math.min(blend, Math.max(barSec * 2, 4));
  } else if (decision.type === "echoOut") {
    // Echo needs a real phrase: 8 bars when outro allows, never a 8–10s limp fade.
    const echoFloor = Math.max(barSec * 8, 16);
    const echoCeil = Math.max(echoFloor, Math.min(availableOutro, barSec * 12));
    blend = Math.min(Math.max(blend, echoFloor), echoCeil);
  } else if (decision.type === "longBlend") {
    blend = Math.max(blend, Math.min(availableOutro, barSec * 16));
  }
  // TZ §5: incompatible keys → avoid *long* harmonic blend (32s), keep an 8-bar phrase.
  if (!decision.harmonic.isNaturallyCompatible && decision.type !== "cutOnOne") {
    const phrase8 = Math.max(barSec * 8, 16);
    const phrase12 = Math.max(barSec * 12, 24);
    if (decision.type === "longBlend" || decision.type === "eqBlend") {
      blend = Math.min(blend, phrase12);
    } else if (decision.type === "smartCrossfade") {
      blend = Math.max(Math.min(blend, phrase8), Math.min(phrase8, availableOutro));
    }
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
      params.incomingVolumeLag = 0.1;
      params.bassDepth = 1.05;
      break;
    case "echoOut":
      // Longer invite: A rings out while B locks under — not a snap fade.
      params.bassSwapAt = 0.28;
      params.handoffAt = 0.58;
      params.outgoingVolumeHold = 0.38;
      params.incomingVolumeLag = 0.1;
      params.bassDepth = 1.1;
      break;
    case "cutOnOne":
      params.bassSwapAt = 0.45;
      params.handoffAt = 0.55;
      params.outgoingVolumeHold = 0.2;
      params.incomingVolumeLag = 0.06;
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
      params.incomingVolumeLag = 0.1;
      params.bassDepth = 1.1;
  }

  if (vocalOut < 0.42) {
    // A already a bed — invite B sooner, but keep lag ≥0.06 so volumes stay smooth.
    params.incomingVolumeLag = Math.max(0.06, params.incomingVolumeLag * 0.7);
    params.outgoingVolumeHold = Math.min(0.7, params.outgoingVolumeHold + 0.1);
    params.bassSwapAt = Math.max(0.14, params.bassSwapAt - 0.04);
  } else {
    params.outgoingVolumeHold = Math.max(0.28, params.outgoingVolumeHold - 0.06);
    params.incomingVolumeLag = Math.min(0.2, params.incomingVolumeLag + 0.04);
    params.handoffAt = Math.min(0.62, params.handoffAt + 0.04);
  }

  if (vocalIn > 0.55 && vocalOut < 0.45) {
    params.incomingVolumeLag = Math.max(0.06, Math.min(0.1, params.incomingVolumeLag));
    params.bassDepth = Math.min(1.15, params.bassDepth + 0.05);
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

  // Vocal Swap: keep handoff after B vocal opens so LAND still has a phrase of dual layer.
  if (params.dsp.mashupMode === "vocalSwap" && params.dsp.instrBPeak >= 0.5) {
    const open = params.dsp.vocalBAt;
    params.handoffAt = Math.min(0.78, Math.max(open + 0.12, params.handoffAt));
    params.dsp.instrBUntil = open;
    // Dual-layer volumes: hold A texture through the remix bar.
    params.outgoingVolumeHold = Math.min(params.outgoingVolumeHold, Math.max(0.22, open - 0.04));
  }

  const craftLabel =
    params.dsp.mashupMode === "acapellaDrop"
      ? "B vocal early"
      : params.dsp.mashupMode === "vocalSwap"
        ? "Vocal Swap"
        : vocalOut < 0.42
          ? "INVITE B vocal"
          : "INVITE B drums";

  const story = [
    transitionTypeLabel(decision.type),
    craftLabel,
    decision.type === "cutOnOne" ? "CUT" : "ONE BASS",
    decision.type === "echoOut" ? "ECHO→LAND" : "MASHUP→LAND",
  ].join(" → ");

  const processing = [
    `TZ type: ${transitionTypeLabel(decision.type)} · ${decision.reason}`,
    `Key A ${a.camelotKey ?? "?"} → B ${b.camelotKey ?? "?"} · ${decision.harmonic.description}`,
    `Mashup: ${params.dsp.mashupMode} · sidechain A ${(params.dsp.sidechainA * 100) | 0}%`,
    beatmatched
      ? `beatmatch → ${Math.round(params.targetBPM)} BPM (A×${params.rateA.toFixed(3)} B×${params.rateB.toFixed(3)})`
      : `no forced beatmatch · rates A×${params.rateA.toFixed(3)} B×${params.rateB.toFixed(3)}`,
    params.pitchCentsB
      ? `Camelot pitch B ${params.pitchCentsB >= 0 ? "+" : ""}${params.pitchCentsB | 0}¢`
      : null,
    `cues A@${cueA.toFixed(1)}s → B@${cueB.toFixed(1)}s · ${bars | 0} bars · ${params.blendDurationSec.toFixed(1)}s`,
    `vocalOut ${(vocalOut * 100) | 0}% / vocalIn ${(vocalIn * 100) | 0}% · B vocal @ ${((params.dsp.vocalBAt * 100) | 0)}%`,
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
