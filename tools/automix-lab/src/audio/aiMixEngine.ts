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
import { runMixCritic, type MixCriticReport } from "./mixCritic";
import { applyPremiumLand } from "./premiumAutomix";

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
  /** OpenSonic/DeckGhost-style preflight — Vocal Safe / Bass Surgeon if needed. */
  critic: MixCriticReport;
  /** Vocal presence measured at the planned cues. */
  vocalOut: number;
  vocalIn: number;
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
export function vocalLevelNear(profile: TrackAIProfile, sec: number, windowSec = 8): number {
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

/**
 * Prefer an earlier instrumental bed so Acapella Drop can fire instead of Safe Exit.
 * Scans [earliest, latest] for the lowest vocal window that still has energy.
 */
function findBestInstrumentalCue(
  profile: TrackAIProfile,
  earliest: number,
  latest: number,
  bpm: number
): { cue: number; vocal: number } {
  const hop = 0.25;
  const lo = Math.max(0, earliest);
  const hi = Math.max(lo, latest);
  let bestSec = snapToBar(Math.min(hi, Math.max(lo, profile.mixOutSec)), bpm);
  let bestVocal = vocalLevelNear(profile, bestSec, 8);
  let bestScore = -1e9;
  for (let sec = lo; sec <= hi; sec += hop * 4) {
    const v = vocalLevelNear(profile, sec, 8);
    const e = energyNear(profile, sec, 8);
    // Prefer bed (low vocal) with remaining groove; slight bias toward later exits.
    const score = (1 - v) * 1.35 + e * 0.45 + ((sec - lo) / Math.max(1, hi - lo)) * 0.12;
    if (score > bestScore) {
      bestScore = score;
      bestVocal = v;
      bestSec = sec;
    }
  }
  return { cue: snapToBar(bestSec, bpm), vocal: bestVocal };
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
  // Prefer a full 16-bar story — rushed 4-bar mashups feel like a blink.
  if (archetype === "seamlessLoop" && availableOutro >= barSec * 14) return 16;
  if (availableOutro >= barSec * 14) return 16;
  if (availableOutro >= barSec * 10) return 12;
  if (availableOutro >= barSec * 7) return 8;
  if (availableOutro >= barSec * 5) return 6;
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
  dsp.dualLayerPeak = craft.dualLayerPeak;
  decisions.push(`Mashup craft: ${craft.label} — ${craft.story}`);

  switch (craft.mode) {
    case "acapellaDrop": {
      // A is the bed under B's dry lead. Peak stays high so gates see one vocal;
      // bake (nuclear carve) only when the outro still has a center vocal.
      dsp.instrAPeak = 0.96;
      dsp.instrAAt = craft.aInstrReadyAt;
      dsp.instrBPeak = 0;
      dsp.instrBUntil = 0.04;
      dsp.vocalBPeak = 0; // dry B — full fidelity lead
      dsp.vocalBAt = craft.bVocalOpenAt;
      dsp.vocalDuckBDb = 0;
      dsp.bakeInstrA = craft.bakeInstrA || vocalOut >= 0.28;
      dsp.bakeInstrB = false;
      dsp.bakeVocalB = false;
      dsp.bakeStems = dsp.bakeInstrA;
      dsp.sidechainA = 0;
      decisions.push("Acapella Drop: A instrumental bed × B vocal on grid");
      break;
    }
    case "safeExit": {
      // A outro still sings — refuse dual mashup, keep a full AutoMix phrase.
      dsp.instrAPeak = 0;
      dsp.instrAAt = 0.5;
      dsp.instrBPeak = 0;
      dsp.instrBUntil = 0.05;
      dsp.vocalBPeak = 0;
      dsp.vocalBAt = 0.85;
      dsp.vocalDuckBDb = 0;
      dsp.bakeInstrA = false;
      dsp.bakeInstrB = false;
      dsp.bakeVocalB = false;
      dsp.bakeStems = false;
      dsp.sidechainA = 0;
      decisions.push(
        "Safe Exit: A still sings → phrase Automix (LOCK/bass/echo), one lead"
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
      // A long lag parks B at silence under a quieter outro (level hole).
      params.incomingVolumeLag = Math.min(params.incomingVolumeLag, 0.05);
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

const PHASE_ALIGN_MIN_CONFIDENCE = 0.62;

export type PhaseAlign = {
  cueA: number;
  cueB: number;
  nudged: boolean;
  deltaA: number;
  deltaB: number;
  note: string | null;
};

function beatFraction(sec: number, downbeatSec: number, beatSec: number): number {
  const x = (sec - downbeatSec) / beatSec;
  let f = x - Math.floor(x);
  if (f < 0) f += 1;
  return f;
}

/** Signed distance in cycles, wrapped to (-0.5, 0.5]. */
function wrapHalf(delta: number): number {
  let x = delta - Math.floor(delta);
  if (x > 0.5) x -= 1;
  return x;
}

function clampMove(
  cue: number,
  delta: number,
  beatSec: number,
  lo: number,
  hi: number
): number {
  const half = 0.5 * beatSec;
  let d = delta;
  if (d > half) d = half;
  if (d < -half) d = -half;
  const minD = lo - cue;
  const maxD = hi - cue;
  if (d < minD) d = minD;
  if (d > maxD) d = maxD;
  if (d > half) d = half;
  if (d < -half) d = -half;
  return d;
}

/**
 * Slip cueA/cueB by at most half a beat so their kick phases match.
 * No-op unless both downbeat confidences are high.
 */
export function alignBeatPhase(opts: {
  cueA: number;
  cueB: number;
  bpmA: number;
  bpmB: number;
  downbeatA: number;
  downbeatB: number;
  confidenceA: number;
  confidenceB: number;
  bpmConfidenceA?: number;
  bpmConfidenceB?: number;
  limitA: [number, number];
  limitB: [number, number];
}): PhaseAlign {
  const stay: PhaseAlign = {
    cueA: opts.cueA,
    cueB: opts.cueB,
    nudged: false,
    deltaA: 0,
    deltaB: 0,
    note: null,
  };
  if (!(opts.bpmA > 30 && opts.bpmB > 30)) return stay;
  if (
    opts.confidenceA < PHASE_ALIGN_MIN_CONFIDENCE ||
    opts.confidenceB < PHASE_ALIGN_MIN_CONFIDENCE
  ) {
    return stay;
  }
  if ((opts.bpmConfidenceA ?? 1) < 0.35 || (opts.bpmConfidenceB ?? 1) < 0.35) return stay;

  const beatA = 60 / opts.bpmA;
  const beatB = 60 / opts.bpmB;
  const fracA = beatFraction(opts.cueA, opts.downbeatA, beatA);
  const fracB = beatFraction(opts.cueB, opts.downbeatB, beatB);
  // Beats to add to B's fraction (and remove from A's) so the grids meet.
  const error = wrapHalf(fracA - fracB);
  if (Math.abs(error) < 0.04) return stay;

  const loA = Math.min(opts.limitA[0], opts.limitA[1]);
  const hiA = Math.max(opts.limitA[0], opts.limitA[1]);
  const loB = Math.min(opts.limitB[0], opts.limitB[1]);
  const hiB = Math.max(opts.limitB[0], opts.limitB[1]);

  let dA = clampMove(opts.cueA, (-error / 2) * beatA, beatA, loA, hiA);
  let dB = clampMove(opts.cueB, (error / 2) * beatB, beatB, loB, hiB);
  let remain = error - (dB / beatB - dA / beatA);
  if (Math.abs(remain) > 0.03) {
    dB = clampMove(opts.cueB, dB + remain * beatB, beatB, loB, hiB);
    remain = error - (dB / beatB - dA / beatA);
    dA = clampMove(opts.cueA, dA - remain * beatA, beatA, loA, hiA);
  }
  if (Math.abs(dA) < 0.004 && Math.abs(dB) < 0.004) return stay;

  const ms = (s: number) => `${s >= 0 ? "+" : ""}${Math.round(s * 1000)}ms`;
  return {
    cueA: opts.cueA + dA,
    cueB: opts.cueB + dB,
    nudged: true,
    deltaA: dA,
    deltaB: dB,
    note: `phase align A ${ms(dA)} · B ${ms(dB)}`,
  };
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
  let beatmatched = decision.beatmatch && tempo != null;
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

  // AutoMix wants a real phrase (12–16 bars), not a Crossfade blink.
  // Prefer an instrumental bed when one exists so Acapella Drop can fire —
  // but never discard a confident Whisper/LRC phrase exit for a random bed.
  const introVocal = vocalLevelNear(b, Math.max(0, b.mixInSec), 8);
  const minOutroSec =
    decision.type === "cutOnOne"
      ? Math.max(12, barSec * 6)
      : Math.max(24, barSec * 12);
  const latestCueA = Math.max(0, a.durationSec - minOutroSec);
  const earliestCueA = Math.min(latestCueA, a.durationSec * 0.58);
  const neuralTrusted =
    /neural|LRC|Whisper|energy×lyrics|lyrics/i.test(a.reason || "") &&
    a.mixOutSec >= earliestCueA &&
    a.mixOutSec <= latestCueA + 0.5;
  const bedHunt = findBestInstrumentalCue(
    a,
    earliestCueA,
    latestCueA,
    a.bpm || bpmGrid
  );
  const neuralVocal = vocalLevelNear(a, cueA, 8);
  // Steal Acapella only when the bed is clearly cleaner than the neural cue
  // and lyrics didn't already plant a strong phrase exit mid-vocal.
  const preferBed =
    bedHunt.vocal < 0.32 &&
    introVocal >= 0.4 &&
    (!neuralTrusted || neuralVocal >= 0.42) &&
    bedHunt.vocal + 0.08 < neuralVocal;
  const acapellaCandidate = preferBed || (neuralVocal < 0.35 && introVocal >= 0.4);
  if (preferBed) {
    cueA = bedHunt.cue;
  } else if (neuralTrusted) {
    cueA = Math.min(latestCueA, Math.max(earliestCueA, a.mixOutSec));
  } else {
    cueA = Math.min(latestCueA, Math.max(earliestCueA, cueA));
  }
  cueA = snapToBar(cueA, a.bpm || bpmGrid);
  if (cueA > latestCueA) {
    cueA = Math.max(0, latestCueA - (latestCueA % Math.max(barSec, 0.001)));
  }

  const maxCueB = Math.max(barSec * 2, Math.min(b.durationSec * 0.28, 48));
  // B mixIn: trust lyrics/neural intro when present (written onto profile.mixInSec).
  if (b.mixInSec > 0.5) cueB = snapMixIn(b.mixInSec, b.bpm || bpmGrid);
  cueB = Math.min(Math.max(0, cueB), maxCueB);

  const availableOutro = Math.max(minOutroSec, a.durationSec - cueA);
  const bars = phraseBars(availableOutro, barSec, archetype);
  // Cap 48s — DJ mashup story, not a blink. Floor ~12 bars when outro allows.
  let blend = Math.min(48, Math.max(minOutroSec, Math.min(bars * barSec, availableOutro)));
  if (decision.type === "cutOnOne") {
    // Last-resort splice — still several bars, never a sample blink.
    blend = Math.min(blend, Math.max(barSec * 6, 12));
  } else if (decision.type === "echoOut") {
    const echoFloor = Math.max(barSec * 12, 24);
    const echoCeil = Math.max(echoFloor, Math.min(availableOutro, barSec * 16));
    blend = Math.min(Math.max(blend, echoFloor), echoCeil);
  } else if (decision.type === "longBlend" || acapellaCandidate) {
    blend = Math.max(blend, Math.min(availableOutro, barSec * 16));
  } else {
    // EQ / Filter / Smart — at least ~12 bars when outro allows.
    blend = Math.max(blend, Math.min(availableOutro, Math.max(barSec * 12, 24)));
  }
  // TZ §5: incompatible keys → keep a phrase, not a 4s cut unless forced.
  if (!decision.harmonic.isNaturallyCompatible && decision.type !== "cutOnOne") {
    const phrase12 = Math.max(barSec * 12, 24);
    const phrase16 = Math.max(barSec * 16, 28);
    if (decision.type === "longBlend" || decision.type === "eqBlend") {
      blend = Math.min(Math.max(blend, phrase12), Math.min(availableOutro, phrase16));
    } else if (decision.type === "smartCrossfade") {
      blend = Math.max(Math.min(blend, phrase12), Math.min(phrase12, availableOutro));
    }
  }
  // Never park cue so late that AutoMix collapses into Crossfade length.
  {
    const want = Math.min(48, Math.max(blend, Math.min(availableOutro, barSec * 12)));
    const notBefore = Math.max(0, a.durationSec - want);
    if (cueA > notBefore) {
      cueA = snapToBar(notBefore, a.bpm || bpmGrid);
      if (cueA > notBefore) cueA = Math.max(0, notBefore);
    }
    const room = Math.max(4, a.durationSec - cueA);
    blend = Math.max(4, Math.min(Math.max(blend, Math.min(room, want)), room));
  }
  params.blendDurationSec = blend;
  params.cueASec = cueA;
  params.cueBSec = cueB;

  // Beat phase: slip at most half a beat when the kick grid is confident.
  // Bar snap already ran — this is a small correction, not a new phrase.
  let phaseNote: string | null = null;
  if (tempo && !abandonStretch) {
    const latestA = Math.max(0, a.durationSec - Math.max(4, params.blendDurationSec));
    const aligned = alignBeatPhase({
      cueA,
      cueB,
      bpmA: a.bpm,
      bpmB: b.bpm,
      downbeatA: a.downbeatSec ?? 0,
      downbeatB: b.downbeatSec ?? 0,
      confidenceA: a.downbeatConfidence ?? 0,
      confidenceB: b.downbeatConfidence ?? 0,
      bpmConfidenceA: a.bpmConfidence,
      bpmConfidenceB: b.bpmConfidence,
      limitA: [0, latestA],
      limitB: [0, maxCueB],
    });
    if (aligned.nudged) {
      cueA = aligned.cueA;
      cueB = aligned.cueB;
      params.cueASec = cueA;
      params.cueBSec = cueB;
      const room = Math.max(4, a.durationSec - cueA);
      if (params.blendDurationSec > room) params.blendDurationSec = room;
      phaseNote = aligned.note;
    }
  }

  let vocalOut = vocalLevelNear(a, cueA, Math.min(12, params.blendDurationSec));
  let vocalIn = vocalLevelNear(b, cueB, Math.min(12, params.blendDurationSec));
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
    // A already a bed — invite B sooner, but keep lag ≥0.08 so volumes stay smooth.
    params.incomingVolumeLag = Math.max(0.08, params.incomingVolumeLag * 0.85);
    params.outgoingVolumeHold = Math.min(0.7, params.outgoingVolumeHold + 0.1);
    params.bassSwapAt = Math.max(0.16, params.bassSwapAt - 0.03);
  } else {
    params.outgoingVolumeHold = Math.max(0.3, params.outgoingVolumeHold - 0.04);
    params.incomingVolumeLag = Math.min(0.22, params.incomingVolumeLag + 0.05);
    params.handoffAt = Math.min(0.64, params.handoffAt + 0.05);
  }

  // Long windows: stretch invite/handoff so mashup doesn't feel like a blink.
  if (params.blendDurationSec >= 20 && decision.type !== "cutOnOne") {
    params.incomingVolumeLag = Math.max(0.1, Math.min(0.22, params.incomingVolumeLag + 0.03));
    params.outgoingVolumeHold = Math.max(params.outgoingVolumeHold, 0.36);
    params.handoffAt = Math.min(0.66, Math.max(params.handoffAt, 0.56));
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

  if (params.dsp.mashupMode === "acapellaDrop") {
    const twelve = Math.max(barSec * 12, 20);
    const sixteen = Math.min(48, Math.max(twelve, barSec * 16));
    const roomNow = Math.max(4, a.durationSec - params.cueASec);
    if (roomNow < twelve * 0.85) {
      const earlier = Math.max(0, a.durationSec - sixteen);
      const mixOut = snapToBar(Math.max(0, a.mixOutSec), a.bpm || bpmGrid);
      const pulled = snapToBar(
        Math.max(earlier, Math.min(params.cueASec, mixOut)),
        a.bpm || bpmGrid
      );
      if (vocalLevelNear(a, pulled, 8) < 0.35) {
        params.cueASec = Math.max(0, Math.min(pulled, Math.max(0, a.durationSec - 4)));
      }
    }
    const room = Math.max(4, a.durationSec - params.cueASec);
    params.blendDurationSec = Math.min(
      48,
      Math.max(params.blendDurationSec, Math.min(room, sixteen))
    );
    vocalOut = vocalLevelNear(a, params.cueASec, Math.min(12, params.blendDurationSec));
    vocalIn = vocalLevelNear(b, params.cueBSec, Math.min(12, params.blendDurationSec));
  }

  // Safe Exit: A still sings. Full AutoMix phrase (LOCK→bass→echo LAND), one lead.
  if (params.dsp.mashupMode === "safeExit") {
    // Prefer Echo Out drama over Cut — Cut only when tempos truly refuse lock.
    if (params.archetype === "cutOnOne" && beatmatched) {
      params.archetype = "echoOut";
    } else if (params.archetype !== "cutOnOne") {
      params.archetype = "echoOut";
    }
    const twelve = Math.max(barSec * 12, 24);
    const sixteen = Math.min(48, Math.max(twelve, barSec * 16));
    const room = Math.max(4, a.durationSec - params.cueASec);
    params.blendDurationSec = Math.min(
      48,
      Math.max(params.blendDurationSec, Math.min(room, sixteen))
    );
    params.handoffAt = Math.min(0.68, Math.max(0.52, params.handoffAt));
    params.outgoingVolumeHold = Math.min(params.outgoingVolumeHold, params.handoffAt - 0.18);
    params.incomingVolumeLag = Math.max(0.1, params.incomingVolumeLag);
    params.bassSwapAt = Math.min(
      Math.max(0.22, params.bassSwapAt),
      params.handoffAt - 0.14
    );
    params.dsp.echoAPeak = Math.max(0.45, Math.min(0.75, params.dsp.echoAPeak || 0.55));
    params.dsp.hpfAPeak = Math.max(0.55, params.dsp.hpfAPeak);
    params.dsp.decisions = [
      ...params.dsp.decisions,
      `Safe Exit · AutoMix phrase ${params.blendDurationSec.toFixed(0)}s · LOCK → ONE BASS → Echo LAND`,
    ];
  }

  // Acapella Drop only: quiet A bed under B vocal, capped echo.
  if (params.dsp.mashupMode === "acapellaDrop" && params.dsp.instrAPeak >= 0.2) {
    const open = Math.max(0.06, params.dsp.vocalBAt);
    params.dsp.vocalBAt = open;
    params.handoffAt = Math.min(0.8, Math.max(open + 0.12, params.handoffAt));
    params.outgoingVolumeHold = Math.min(params.outgoingVolumeHold, 0.28);
    params.dsp.echoAPeak = Math.min(0.22, params.dsp.echoAPeak * 0.35);
    params.dsp.decisions = [
      ...params.dsp.decisions,
      "Acapella Drop: A bed under B · echo capped",
    ];
  }

  // Acapella wants tempo lock when stretch is viable.
  if (
    params.dsp.mashupMode === "acapellaDrop" &&
    tempo &&
    Math.max(Math.abs(tempo.rateA - 1), Math.abs(tempo.rateB - 1)) <= 0.16
  ) {
    params.rateA = tempo.rateA;
    params.rateB = tempo.rateB;
    params.targetBPM = tempo.targetBPM;
    beatmatched = true;
  }

  params.dsp.guardVocalOut = vocalOut;
  params.dsp.guardVocalIn = vocalIn;

  // Phrase-snap LAND first so the critic can still pull bass/vocals back into budget.
  const drafted = applyPremiumLand({
    params,
    profileA: a,
    profileB: b,
    reason: "",
    story: "",
    archetype,
    transitionType: decision.type,
    beatmatched,
    processing: [],
    critic: {
      ok: true,
      score: 0,
      gates: [],
      vocalClashBeats: 0,
      vocalClashFrac: 0,
      bassClashFrac: 0,
      bassClashBeats: 0,
      fixes: [],
      mode: "pass",
    },
    vocalOut,
    vocalIn,
  });

  // Mix Critic (OpenSonic verify + DeckGhost Vocal Safe / Bass Surgeon).
  const critic = runMixCritic({
    params: drafted.params,
    vocalOut,
    vocalIn,
    bpm: bpmGrid,
    transitionType: decision.type,
    harmonicOk: decision.harmonic.isHarmonicallyViable,
    beatmatched,
  });

  const craftLabel =
    params.dsp.mashupMode === "acapellaDrop"
      ? "A instr × B vocal"
      : params.dsp.mashupMode === "safeExit"
        ? "Safe Exit (A still sings)"
        : vocalOut < 0.35
          ? "INVITE B vocal"
          : "INVITE B drums";

  const story = [
    transitionTypeLabel(decision.type),
    craftLabel,
    decision.type === "cutOnOne" ? "CUT" : "ONE BASS",
    params.pitchCentsB ? `KEY ${params.pitchCentsB >= 0 ? "+" : ""}${params.pitchCentsB | 0}¢` : null,
    decision.type === "echoOut" ? "ECHO→LAND" : "MASHUP→LAND",
  ]
    .filter(Boolean)
    .join(" → ");

  const criticLine = critic.ok
    ? `Mix Critic ${critic.score}/100 · pass`
    : `Mix Critic ${critic.score}/100 · ${critic.mode} · ${critic.fixes.join(" + ") || "review"}`;

  const processing = [
    `TZ type: ${transitionTypeLabel(decision.type)} · ${decision.reason}`,
    `Key A ${a.camelotKey ?? "?"} → B ${b.camelotKey ?? "?"} · ${decision.harmonic.description}`,
    criticLine,
    ...critic.gates.map((g) => `${g.ok ? "✓" : "✗"} ${g.label}: ${g.detail}`),
    `Mashup: ${params.dsp.mashupMode} · sidechain A ${(params.dsp.sidechainA * 100) | 0}%`,
    beatmatched
      ? `beatmatch → ${Math.round(params.targetBPM)} BPM (A×${params.rateA.toFixed(3)} B×${params.rateB.toFixed(3)})`
      : `no forced beatmatch · rates A×${params.rateA.toFixed(3)} B×${params.rateB.toFixed(3)}`,
    params.pitchCentsB
      ? `Camelot pitch B ${params.pitchCentsB >= 0 ? "+" : ""}${params.pitchCentsB | 0}¢`
      : null,
    phaseNote,
    `cues A@${params.cueASec.toFixed(1)}s → B@${params.cueBSec.toFixed(1)}s · ${(params.blendDurationSec / barSec) | 0} bars · ${params.blendDurationSec.toFixed(1)}s`,
    `vocalOut ${(vocalOut * 100) | 0}% / vocalIn ${(vocalIn * 100) | 0}% · B vocal @ ${((params.dsp.vocalBAt * 100) | 0)}%`,
    ...params.dsp.decisions,
  ].filter(Boolean) as string[];

  return {
    ...drafted,
    reason: processing.slice(0, 2).join(" · "),
    story: `${story} → ${drafted.story.replace(/^\s*→\s*/, "")}`,
    processing: [
      ...processing,
      ...drafted.processing.filter((line) => line.startsWith("Premium") || line.startsWith("✓")),
    ],
    critic,
    vocalOut,
    vocalIn,
  };
}

/**
 * Re-measure isn't required — callers pass cue vocals after coach/LAND mutations.
 * Mutates params when Vocal Safe or Bass Surgeon still fail.
 */
export function recheckMix(
  plan: AIMixPlan,
  vocalOut = plan.vocalOut,
  vocalIn = plan.vocalIn
): AIMixPlan {
  plan.vocalOut = vocalOut;
  plan.vocalIn = vocalIn;
  plan.params.dsp.guardVocalOut = vocalOut;
  plan.params.dsp.guardVocalIn = vocalIn;
  const bpm =
    plan.params.targetBPM > 30 ? plan.params.targetBPM : plan.profileB.bpm || 120;
  plan.critic = runMixCritic({
    params: plan.params,
    vocalOut,
    vocalIn,
    bpm,
    transitionType: plan.transitionType,
    harmonicOk: plan.critic?.gates?.find((g) => g.id === "harmonic")?.ok ?? true,
    beatmatched: plan.beatmatched,
  });
  return plan;
}
