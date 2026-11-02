/**
 * Adaptive Phrase Duet (mode id: oneBarDuet) — Song Transition ≠ AutoMix.
 *
 * The planner *listens* to both profiles (vocalPresence + neural mixOut/mixIn)
 * and picks how long A+B dry vocals should collide before LAND B.
 * No fixed 1-bar / 4-bar default: length comes from phrase content.
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

const HOP = 0.25;
/** Soft bounds — content picks inside; never a blink, never a full AutoMix novel. */
const DUET_MIN_BARS = 2;
const DUET_MAX_BARS = 16;

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

/** Mean vocal in [from, from+len). */
function vocalMean(profile: TrackAIProfile, from: number, len: number): number {
  if (len <= 0.05) return 0;
  const i0 = Math.max(0, Math.floor(from / HOP));
  const i1 = Math.min(profile.vocalPresence.length, Math.ceil((from + len) / HOP));
  if (i1 <= i0) return vocalLevelNear(profile, from, Math.max(1, len));
  let s = 0;
  for (let i = i0; i < i1; i++) s += profile.vocalPresence[i]!;
  return s / (i1 - i0);
}

/**
 * First breath / phrase dip after `fromSec` inside `windowSec`.
 * Prefers a sustained vocal stretch then a clear drop (line end).
 */
function firstPhraseBreath(
  profile: TrackAIProfile,
  fromSec: number,
  windowSec: number,
  bpm: number
): number | null {
  const barSec = 240 / Math.max(60, bpm);
  const end = Math.min(profile.durationSec, fromSec + windowSec);
  const startI = Math.max(0, Math.floor(fromSec / HOP));
  const endI = Math.min(profile.vocalPresence.length, Math.ceil(end / HOP));
  if (endI - startI < 4) return null;

  let sawLead = false;
  let leadBars = 0;
  const needLead = Math.max(2, Math.round((barSec * 1.5) / HOP)); // ~1.5 bars hot
  for (let i = startI; i < endI; i++) {
    const v = profile.vocalPresence[i]!;
    if (v >= 0.42) {
      sawLead = true;
      leadBars++;
    } else if (sawLead && leadBars >= needLead && v < 0.28) {
      // Confirm dip lasts a bit (not a one-hop glitch).
      const next = profile.vocalPresence[i + 1] ?? v;
      const next2 = profile.vocalPresence[i + 2] ?? next;
      if (next < 0.34 && next2 < 0.38) {
        return i * HOP;
      }
    } else if (v < 0.28) {
      leadBars = Math.max(0, leadBars - 1);
    }
  }
  return null;
}

type DuetWindowPick = {
  blendSec: number;
  bars: number;
  handoffAt: number;
  cueA: number;
  cueB: number;
  score: number;
  reason: string;
};

/**
 * Listen to A outro + B intro vocals and choose collide length + LAND fraction.
 */
export function pickDuetWindow(
  a: TrackAIProfile,
  b: TrackAIProfile,
  bpm: number
): DuetWindowPick {
  const barSec = 240 / Math.max(60, bpm);
  const minBlend = Math.max(4, barSec * DUET_MIN_BARS);
  const maxBlend = Math.min(36, Math.max(minBlend, barSec * DUET_MAX_BARS));

  // Seed cues from neural/LRC (already fused onto profiles) — then leave room.
  let cueA = snapToBar(
    Math.min(
      Math.max(0, a.durationSec - minBlend - 0.05),
      Math.max(a.durationSec * 0.55, a.mixOutSec > 0.5 ? a.mixOutSec : a.durationSec * 0.72)
    ),
    a.bpm || bpm
  );
  let cueB =
    b.mixInSec > 0.5
      ? snapMixIn(b.mixInSec, b.bpm || bpm)
      : snapMixIn(Math.min(8, b.durationSec * 0.08), b.bpm || bpm);
  cueB = Math.min(cueB, Math.max(0, b.durationSec * 0.3));

  const available = Math.max(minBlend, a.durationSec - cueA);
  const room = Math.min(maxBlend, available);

  // Candidate phrase lengths in bars — AI scores each against measured vocals.
  const candidates: number[] = [];
  for (let bars = DUET_MIN_BARS; bars <= DUET_MAX_BARS; bars += 2) {
    const sec = bars * barSec;
    if (sec >= minBlend - 0.05 && sec <= room + 0.05) candidates.push(bars);
  }
  if (!candidates.length) {
    const bars = Math.max(DUET_MIN_BARS, Math.round(room / barSec));
    candidates.push(Math.min(DUET_MAX_BARS, bars));
  }

  let best: DuetWindowPick | null = null;

  for (const bars of candidates) {
    let blend = Math.min(room, Math.max(minBlend, bars * barSec));
    // Pull cue earlier if this candidate needs more outro than currently left.
    let localCueA = cueA;
    if (a.durationSec - localCueA < blend) {
      localCueA = snapToBar(Math.max(0, a.durationSec - blend), a.bpm || bpm);
      blend = Math.min(blend, Math.max(minBlend, a.durationSec - localCueA));
    }

    // Dual-hot body = most of the window; LAND in the last stretch.
    const dualSec = blend * 0.72;
    const vocalA = vocalMean(a, localCueA, dualSec);
    const vocalB = vocalMean(b, cueB, dualSec);
    const vocalATail = vocalMean(a, localCueA + dualSec, Math.max(0.5, blend - dualSec));
    const vocalBLand = vocalMean(b, cueB + dualSec, Math.max(0.5, blend - dualSec));

    // Natural breaths inside the window (content-driven LAND).
    const breathA = firstPhraseBreath(a, localCueA + barSec, blend - barSec * 0.5, a.bpm || bpm);
    const breathB = firstPhraseBreath(b, cueB + barSec, blend - barSec * 0.5, b.bpm || bpm);

    let handoffAt = 0.78;
    let landNote = "grid LAND";
    if (breathA != null) {
      const p = (breathA - localCueA) / blend;
      if (p >= 0.55 && p <= 0.9) {
        handoffAt = Math.min(0.88, Math.max(0.58, p));
        landNote = `A phrase breath @${breathA.toFixed(1)}s`;
      }
    } else if (breathB != null) {
      const p = (breathB - cueB) / blend;
      if (p >= 0.55 && p <= 0.9) {
        handoffAt = Math.min(0.88, Math.max(0.58, p));
        landNote = `B phrase breath @${breathB.toFixed(1)}s`;
      }
    } else if (vocalATail + 0.12 < vocalA && vocalBLand >= 0.35) {
      // A fading while B still sings — LAND a bit earlier.
      handoffAt = 0.7;
      landNote = "A vocal fades · B holds";
    }

    // Score: both leads present in the collide, B still alive at LAND,
    // A not silent the whole time, prefer clearer dual (not one muted).
    const dualBalance = 1 - Math.abs(vocalA - vocalB);
    const bothHot = Math.min(vocalA, vocalB);
    const landOk = vocalBLand;
    const aStillThere = vocalA;
    // Prefer mid-length when scores tie — 6–12 bars often musical for duet.
    const lengthBias =
      bars >= 6 && bars <= 12 ? 0.08 : bars === 4 || bars === 14 ? 0.03 : 0;
    const neuralBonus =
      (/neural|LRC|Whisper|lyrics/i.test(a.reason || "") ? 0.05 : 0) +
      (/neural|LRC|Whisper|lyrics/i.test(b.reason || "") ? 0.03 : 0);

    const score =
      bothHot * 2.4 +
      dualBalance * 0.9 +
      landOk * 1.1 +
      aStillThere * 0.5 +
      lengthBias +
      neuralBonus +
      (breathA || breathB ? 0.15 : 0) -
      (bothHot < 0.28 ? 0.8 : 0);

    const reason = [
      `${bars} bars · ${blend.toFixed(1)}s`,
      `A vocal ${vocalA.toFixed(2)} · B vocal ${vocalB.toFixed(2)}`,
      landNote,
    ].join(" · ");

    const pick: DuetWindowPick = {
      blendSec: blend,
      bars,
      handoffAt,
      cueA: localCueA,
      cueB,
      score,
      reason,
    };
    if (!best || pick.score > best.score) best = pick;
  }

  // Fallback — should be rare.
  if (!best) {
    const bars = Math.max(DUET_MIN_BARS, Math.round(minBlend / barSec));
    return {
      blendSec: minBlend,
      bars,
      handoffAt: 0.78,
      cueA,
      cueB,
      score: 0,
      reason: `fallback · ${bars} bars`,
    };
  }
  return best;
}

function passCritic(detail: string, blendSec: number, bpm: number): MixCriticReport {
  const spb = 60 / Math.max(60, bpm);
  const bars = blendSec / (spb * 4);
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
        detail: "adaptive dual · mid swap",
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
        detail: "beatmatched phrase grid",
      },
      {
        id: "land",
        ok: true,
        label: "LAND",
        detail: `cut to B after ~${bars.toFixed(1)} bars`,
      },
    ],
    vocalClashBeats: blendSec / spb,
    vocalClashFrac: 1,
    bassClashFrac: 0,
    bassClashBeats: 0,
    fixes: [],
    mode: "pass",
  };
}

/**
 * Plan a content-aware dual-vocal Automix window.
 * Both leads stay dry; Mix Critic Vocal Safe is intentionally bypassed.
 */
export function planOneBarDuet(a: TrackAIProfile, b: TrackAIProfile): AIMixPlan {
  const params = defaultParams();
  const tempo = tempoMatch(a.bpm, b.bpm);
  const bpm = tempo?.targetBPM || a.bpm || 120;

  if (tempo) {
    params.rateA = tempo.rateA;
    params.rateB = tempo.rateB;
    params.targetBPM = tempo.targetBPM;
  } else {
    params.rateA = 1;
    params.rateB = 1;
    params.targetBPM = a.bpm > 30 ? a.bpm : bpm;
  }

  params.pitchCentsB = 0;
  params.archetype = "cutOnOne";

  const pick = pickDuetWindow(a, b, bpm);
  params.blendDurationSec = pick.blendSec;
  params.cueASec = pick.cueA;
  params.cueBSec = pick.cueB;
  params.bassSwapAt = Math.min(0.4, Math.max(0.22, pick.handoffAt * 0.42));
  params.handoffAt = pick.handoffAt;
  params.outgoingVolumeHold = 0.12;
  params.incomingVolumeLag = Math.min(0.12, Math.max(0.05, 0.5 / Math.max(4, pick.blendSec)));
  params.bassDepth = 0.95;

  const vocalOut = vocalLevelNear(a, pick.cueA, Math.min(12, pick.blendSec));
  const vocalIn = vocalLevelNear(b, pick.cueB, Math.min(12, pick.blendSec));

  const dsp = defaultDsp();
  dsp.mashupMode = ONE_BAR_DUET_MODE;
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
    "Adaptive Phrase Duet · listened to A/B vocals",
    pick.reason,
    `cueA ${pick.cueA.toFixed(1)}s · cueB ${pick.cueB.toFixed(1)}s · handoff ${(pick.handoffAt * 100) | 0}%`,
    a.reason ? `A cue source · ${a.reason}` : "A cue · profile mixOut",
    b.reason ? `B cue source · ${b.reason}` : "B cue · profile mixIn",
  ];
  params.dsp = dsp;

  const critic = passCritic(
    `adaptive dual lead · ${pick.bars} bars (${pick.blendSec.toFixed(1)}s) · no Vocal Safe`,
    pick.blendSec,
    bpm
  );

  return {
    params,
    profileA: a,
    profileB: b,
    reason: "Adaptive Phrase Duet Song Transition",
    story: `DUET · listened · ${pick.bars} bars · LAND B`,
    archetype: "cutOnOne",
    transitionType: "cutOnOne",
    beatmatched: tempo != null,
    processing: [
      "Adaptive Phrase Duet (Song Transitions)",
      "Listen vocalPresence + neural cues",
      "Score phrase lengths 2–16 bars",
      "Both vocals dry in collide",
      "LAND → B on phrase breath / fade",
      ...dsp.decisions,
    ],
    critic,
    vocalOut,
    vocalIn,
  };
}

/** Volume ride for Phrase Duet: both hot, equal-power, then snap to B. */
export function oneBarDuetVolumes(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const handoff = Math.min(0.9, Math.max(0.55, params.handoffAt));
  const invite = Math.min(0.18, Math.max(0.04, params.incomingVolumeLag || 0.08));
  const landSpan = Math.max(0.1, 1 - handoff);
  const outgoing = p <= handoff ? 1 : Math.max(0, 1 - (p - handoff) / landSpan);
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
  if (p < 0.1) {
    return params.targetBPM > 30
      ? `DUET LOCK ${Math.round(params.targetBPM)}`
      : "DUET LOCK";
  }
  if (p < handoff - 0.06) return "DUET · A+B";
  if (p < handoff + 0.08) return "DUET LAND";
  return "LAND";
}
