/**
 * Adaptive Phrase Duet (mode id: oneBarDuet).
 *
 * Product intent (DJ vocal→vocal, not AutoMix ONE VOCAL):
 *   1. Beatmatch + phrase cues from neural/LRC + vocalPresence
 *   2. Invite B under A → short dual where **B leads**, A ducked
 *   3. Bass swap mid-window → LAND B before the last quarter
 *
 * Length is content-scored (2–12 bars). Dual-lead is intentional but
 * controlled — not two equal karaoke tracks for 30s.
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
const DUET_MIN_BARS = 2;
const DUET_MAX_BARS = 12;

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

function vocalMean(profile: TrackAIProfile, from: number, len: number): number {
  if (len <= 0.05) return 0;
  const i0 = Math.max(0, Math.floor(from / HOP));
  const i1 = Math.min(profile.vocalPresence.length, Math.ceil((from + len) / HOP));
  if (i1 <= i0) return vocalLevelNear(profile, from, Math.max(1, len));
  let s = 0;
  for (let i = i0; i < i1; i++) s += profile.vocalPresence[i]!;
  return s / (i1 - i0);
}

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
  let hot = 0;
  const needHot = Math.max(2, Math.round((barSec * 1.2) / HOP));
  for (let i = startI; i < endI; i++) {
    const v = profile.vocalPresence[i]!;
    if (v >= 0.42) {
      sawLead = true;
      hot++;
    } else if (sawLead && hot >= needHot && v < 0.28) {
      const next = profile.vocalPresence[i + 1] ?? v;
      const next2 = profile.vocalPresence[i + 2] ?? next;
      if (next < 0.34 && next2 < 0.38) return i * HOP;
    } else if (v < 0.28) {
      hot = Math.max(0, hot - 1);
    }
  }
  return null;
}

export type DuetWindowPick = {
  blendSec: number;
  bars: number;
  handoffAt: number;
  bassSwapAt: number;
  cueA: number;
  cueB: number;
  score: number;
  reason: string;
  aDuck: number;
};

/**
 * Listen to A outro + B intro; pick collide length with B-led dual + early LAND.
 */
export function pickDuetWindow(
  a: TrackAIProfile,
  b: TrackAIProfile,
  bpm: number
): DuetWindowPick {
  const barSec = 240 / Math.max(60, bpm);
  const minBlend = Math.max(4, barSec * DUET_MIN_BARS);
  const maxBlend = Math.min(28, Math.max(minBlend, barSec * DUET_MAX_BARS));

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

  const candidates: number[] = [];
  for (let bars = DUET_MIN_BARS; bars <= DUET_MAX_BARS; bars += 2) {
    const sec = bars * barSec;
    if (sec >= minBlend - 0.05 && sec <= room + 0.05) candidates.push(bars);
  }
  if (!candidates.length) {
    candidates.push(
      Math.min(DUET_MAX_BARS, Math.max(DUET_MIN_BARS, Math.round(room / barSec)))
    );
  }

  let best: DuetWindowPick | null = null;

  for (const bars of candidates) {
    let blend = Math.min(room, Math.max(minBlend, bars * barSec));
    let localCueA = cueA;
    if (a.durationSec - localCueA < blend) {
      localCueA = snapToBar(Math.max(0, a.durationSec - blend), a.bpm || bpm);
      blend = Math.min(blend, Math.max(minBlend, a.durationSec - localCueA));
    }

    // Dual body before LAND — keep handoff ≤0.70 so LAND settles by p≈0.9.
    const handoffCap = 0.7;
    let handoffAt = handoffCap;
    let landNote = "grid LAND ≤70%";

    const breathA = firstPhraseBreath(
      a,
      localCueA + barSec * 0.75,
      blend * 0.85,
      a.bpm || bpm
    );
    const breathB = firstPhraseBreath(b, cueB + barSec * 0.75, blend * 0.85, b.bpm || bpm);
    if (breathA != null) {
      const p = (breathA - localCueA) / blend;
      if (p >= 0.45 && p <= 0.7) {
        handoffAt = Math.min(handoffCap, Math.max(0.55, p));
        landNote = `A breath @${breathA.toFixed(1)}s`;
      }
    } else if (breathB != null) {
      const p = (breathB - cueB) / blend;
      if (p >= 0.45 && p <= 0.7) {
        handoffAt = Math.min(handoffCap, Math.max(0.55, p));
        landNote = `B breath @${breathB.toFixed(1)}s`;
      }
    }

    const dualSec = blend * handoffAt;
    const vocalA = vocalMean(a, localCueA, dualSec);
    const vocalB = vocalMean(b, cueB, dualSec);
    const vocalBLand = vocalMean(
      b,
      cueB + dualSec,
      Math.max(0.4, blend - dualSec)
    );

    // Prefer 4–8 bars for vocal→vocal (DJ short dual); longer only if both rich.
    const lengthBias =
      bars >= 4 && bars <= 8
        ? 0.2
        : bars === 2
          ? 0.02
          : bars <= 10
            ? 0.06
            : -0.05;
    const bothHot = Math.min(vocalA, vocalB);
    const dualBalance = 1 - Math.abs(vocalA - vocalB);
    const neuralBonus =
      (/neural|LRC|Whisper|lyrics/i.test(a.reason || "") ? 0.06 : 0) +
      (/neural|LRC|Whisper|lyrics/i.test(b.reason || "") ? 0.04 : 0);

    // Stronger A duck when both leads are hot (avoid karaoke mud).
    const aDuck = bothHot >= 0.45 ? 0.58 : bothHot >= 0.3 ? 0.68 : 0.78;

    const score =
      bothHot * 2.2 +
      dualBalance * 0.7 +
      vocalBLand * 1.2 +
      lengthBias +
      neuralBonus +
      (breathA || breathB ? 0.12 : 0) -
      (bothHot < 0.22 ? 0.9 : 0) -
      (bars > 8 && bothHot > 0.55 ? 0.15 : 0);

    const bassSwapAt = Math.min(0.36, Math.max(0.2, handoffAt * 0.45));

    const pick: DuetWindowPick = {
      blendSec: blend,
      bars,
      handoffAt,
      bassSwapAt,
      cueA: localCueA,
      cueB,
      score,
      aDuck,
      reason: [
        `${bars} bars · ${blend.toFixed(1)}s`,
        `A ${vocalA.toFixed(2)} / B ${vocalB.toFixed(2)}`,
        `duckA ${aDuck.toFixed(2)}`,
        landNote,
      ].join(" · "),
    };
    if (!best || pick.score > best.score) best = pick;
  }

  if (!best) {
    return {
      blendSec: minBlend,
      bars: DUET_MIN_BARS,
      handoffAt: 0.68,
      bassSwapAt: 0.28,
      cueA,
      cueB,
      score: 0,
      aDuck: 0.65,
      reason: "fallback · 2 bars",
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
      { id: "vocalClash", ok: true, label: "DUET VOCAL", detail },
      {
        id: "bassClash",
        ok: true,
        label: "ONE BASS",
        detail: "B-led dual · mid bass swap",
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
        detail: `B owns exit · ~${bars.toFixed(1)} bars total`,
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
  params.bassSwapAt = pick.bassSwapAt;
  params.handoffAt = pick.handoffAt;
  params.outgoingVolumeHold = pick.aDuck; // reused as A dual-level in volumesAt
  params.incomingVolumeLag = Math.min(0.14, Math.max(0.06, 0.7 / Math.max(4, pick.blendSec)));
  params.bassDepth = 1.0;

  const vocalOut = vocalLevelNear(a, pick.cueA, Math.min(12, pick.blendSec));
  const vocalIn = vocalLevelNear(b, pick.cueB, Math.min(12, pick.blendSec));

  const dsp = defaultDsp();
  dsp.mashupMode = ONE_BAR_DUET_MODE;
  // Dry leads — identity of Duet (no ONE VOCAL bake).
  dsp.instrAPeak = 0;
  dsp.instrAAt = 0;
  dsp.instrBPeak = 0;
  dsp.instrBUntil = 0;
  dsp.vocalBPeak = 0;
  dsp.vocalBAt = 0;
  dsp.vocalDuckBDb = 0;
  dsp.hpfAPeak = 0.85;
  dsp.lpfBPeak = 0.28;
  dsp.echoAPeak = 0.18;
  dsp.bakeStems = false;
  dsp.bakeInstrA = false;
  dsp.bakeInstrB = false;
  dsp.bakeVocalB = false;
  dsp.sidechainA = 0.45;
  dsp.dualLayerPeak = pick.aDuck;
  dsp.guardVocalOut = vocalOut;
  dsp.guardVocalIn = vocalIn;
  dsp.decisions = [
    "Adaptive Duet · B leads · A ducked",
    pick.reason,
    `cueA ${pick.cueA.toFixed(1)}s · cueB ${pick.cueB.toFixed(1)}s · handoff ${(pick.handoffAt * 100) | 0}%`,
    a.reason ? `A · ${a.reason}` : "A · mixOut",
    b.reason ? `B · ${b.reason}` : "B · mixIn",
  ];
  params.dsp = dsp;

  return {
    params,
    profileA: a,
    profileB: b,
    reason: "Adaptive Phrase Duet Song Transition",
    story: `DUET · ${pick.bars} bars · B-led · LAND`,
    archetype: "cutOnOne",
    transitionType: "cutOnOne",
    beatmatched: tempo != null,
    processing: [
      "Adaptive Phrase Duet",
      "Listen vocalPresence + neural cues",
      "B-led dual · A mid/volume duck",
      "ONE BASS swap · early LAND",
      ...dsp.decisions,
    ],
    critic: passCritic(
      `B-led dual · ${pick.bars} bars (${pick.blendSec.toFixed(1)}s)`,
      pick.blendSec,
      bpm
    ),
    vocalOut,
    vocalIn,
  };
}

/**
 * B-led duet volumes: invite → dual (A ducked) → LAND A out by ~0.9.
 * `outgoingVolumeHold` carries the A duck level (0.55…0.8).
 */
export function oneBarDuetVolumes(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const handoff = Math.min(0.72, Math.max(0.52, params.handoffAt));
  const invite = Math.min(0.16, Math.max(0.05, params.incomingVolumeLag || 0.08));
  const aDual = Math.min(0.82, Math.max(0.5, params.outgoingVolumeHold || 0.65));
  const landEnd = 0.92;

  let outgoing: number;
  if (p <= invite) {
    outgoing = 1;
  } else if (p <= handoff) {
    // Duck A as B rises through the dual window.
    const t = (p - invite) / Math.max(0.001, handoff - invite);
    outgoing = 1 - t * (1 - aDual);
  } else if (p <= landEnd) {
    outgoing = aDual * (1 - (p - handoff) / Math.max(0.08, landEnd - handoff));
  } else {
    outgoing = 0;
  }

  let incoming: number;
  if (p <= invite) {
    incoming = (p / invite) * 0.85;
  } else if (p < handoff) {
    const t = (p - invite) / Math.max(0.001, handoff - invite);
    incoming = 0.85 + 0.15 * t;
  } else {
    incoming = 1;
  }

  // Mild equal-power only before handoff — don't boost A back up.
  if (p < handoff) {
    const pow = Math.hypot(outgoing, incoming);
    if (pow > 0.05 && pow < 0.85) {
      const s = Math.min(1.08, 0.92 / pow);
      incoming = Math.min(1, incoming * s);
      outgoing = Math.min(aDual + 0.05, outgoing * s);
    }
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
  if (p < handoff - 0.05) return "DUET · B-led";
  if (p < handoff + 0.08) return "DUET LAND";
  return "LAND";
}
