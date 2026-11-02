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
  bassGainDbAt,
  defaultDsp,
  defaultParams,
  tempoMatch,
  volumesAt,
  type MashupParams,
} from "./envelopes";
import { planAutomix, vocalLevelNear, type AIMixPlan } from "./aiMixEngine";
import type { MixCriticReport } from "./mixCritic";
import { camelotMatch } from "./keyCamelot";
import { snapProgressToBar } from "./premiumAutomix";

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
  beats: number;
  handoffAt: number;
  bassSwapAt: number;
  cueA: number;
  cueB: number;
  score: number;
  reason: string;
  aDuck: number;
  /** Peak dual vocal heat 0…1 — drives soft Mid/Side carve on A. */
  bothHot: number;
  vocalA: number;
  vocalB: number;
};

/**
 * Listen to A outro + B intro; pick collide length for vocal stack + early LAND.
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
      beats: bars * 4,
      handoffAt,
      bassSwapAt,
      cueA: localCueA,
      cueB,
      score,
      aDuck,
      bothHot,
      vocalA,
      vocalB,
      reason: [
        `${bars} bars (${bars * 4} beats) · ${blend.toFixed(1)}s`,
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
      beats: DUET_MIN_BARS * 4,
      handoffAt: 0.68,
      bassSwapAt: 0.28,
      cueA,
      cueB,
      score: 0,
      aDuck: 0.65,
      bothHot: 0,
      vocalA: 0,
      vocalB: 0,
      reason: "fallback · 2 bars",
    };
  }
  return best;
}

function critiqueDuetPlan(
  params: MashupParams,
  detail: string,
  bpm: number,
  harmonicOk: boolean,
  beatmatched: boolean
): MixCriticReport {
  const blendSec = Math.max(1, params.blendDurationSec);
  const spb = 60 / Math.max(60, bpm);
  const bars = blendSec / (spb * 4);
  let bassClash = 0;
  let landOk = true;
  for (let i = 0; i <= 40; i++) {
    const p = i / 40;
    const bass = bassGainDbAt(p, params);
    const vols = volumesAt(p, params);
    if (
      p > 0.12 &&
      p < 0.88 &&
      bass.outgoing > -8 &&
      bass.incoming > -8 &&
      vols.outgoing > 0.1 &&
      vols.incoming > 0.25
    ) {
      bassClash++;
    }
    if (p >= 0.9 && (vols.outgoing > 0.12 || vols.incoming < 0.85)) landOk = false;
  }
  const landTimingOk = params.handoffAt <= 0.74;
  const bassOk = bassClash <= 2;
  const hasFx =
    (params.dsp.lpfBPeak || 0) >= 0.35 ||
    (params.dsp.echoAPeak || 0) >= 0.28 ||
    (params.dsp.hpfAPeak || 0) >= 0.7;
  const gates = [
    {
      id: "vocalClash" as const,
      ok: true,
      label: "DUET VOCAL",
      detail,
    },
    {
      id: "bassClash" as const,
      ok: bassOk,
      label: "ONE BASS",
      detail: bassOk ? "bass/kick swap clean" : `dual-bass samples=${bassClash}`,
    },
    {
      id: "harmonic" as const,
      ok: harmonicOk,
      label: "Key / Camelot",
      detail: harmonicOk
        ? Math.abs(params.pitchCentsB) >= 20
          ? `pitch ${params.pitchCentsB >= 0 ? "+" : ""}${params.pitchCentsB | 0}¢`
          : "compatible"
        : "key clash — should not dual",
    },
    {
      id: "tempo" as const,
      ok: beatmatched,
      label: "Tempo lock",
      detail: beatmatched
        ? `beatmatched → ${Math.round(bpm)} BPM`
        : "no tempo lock — off-grid dual",
    },
    {
      id: "land" as const,
      ok: landOk && landTimingOk && hasFx,
      label: "LAND + FX",
      detail:
        landOk && landTimingOk && hasFx
          ? `B owns exit · FX on · ~${bars.toFixed(1)} bars`
          : `LAND/FX weak handoff=${params.handoffAt.toFixed(2)} echo=${(
              params.dsp.echoAPeak || 0
            ).toFixed(2)}`,
    },
  ];
  const passed = gates.filter((g) => g.ok).length;
  return {
    ok: gates.every((g) => g.ok),
    score: Math.round((passed / gates.length) * 100),
    gates,
    vocalClashBeats: blendSec / spb,
    vocalClashFrac: 1,
    bassClashFrac: bassClash / 41,
    bassClashBeats: bassClash,
    fixes: [],
    mode: "pass",
  };
}

export function planOneBarDuet(a: TrackAIProfile, b: TrackAIProfile): AIMixPlan {
  // Duet needs a real lock. Wider stretch (±18%) + Camelot ±3 semitones.
  const tempo = tempoMatch(a.bpm, b.bpm, 0.18);
  const harmonic = camelotMatch(a.camelotKey, b.camelotKey, 3);

  // Quality gate: off-tempo or unpitchable keys → Automix (already stronger).
  if (!tempo || !harmonic.isHarmonicallyViable) {
    const fallback = planAutomix(a, b);
    const why = [
      !tempo ? "BPM far" : null,
      !harmonic.isHarmonicallyViable ? harmonic.description : null,
    ]
      .filter(Boolean)
      .join(" · ");
    return {
      ...fallback,
      reason: `Duet quality gate → Automix (${why})`,
      story: `DUET SAFE · ${fallback.story}`,
      processing: [
        `Duet refused: ${why || "quality"}`,
        "Fell back to Automix (better than off-key / off-grid dual)",
        ...fallback.processing,
      ],
    };
  }

  const params = defaultParams();
  const bpm = tempo.targetBPM;
  params.rateA = tempo.rateA;
  params.rateB = tempo.rateB;
  params.targetBPM = tempo.targetBPM;
  // Duet may push ±300¢ when Camelot needs it.
  params.pitchCentsB = Math.max(-300, Math.min(300, harmonic.pitchShiftCents));

  const energyOut = energyMean(a, Math.max(0, a.durationSec * 0.7), a.durationSec * 0.25);
  const energyIn = energyMean(b, 0, Math.min(12, b.durationSec * 0.2));
  const energyShift = Math.abs(energyIn - energyOut);
  // Filter drama when energy jumps; otherwise classic drop-swap.
  params.archetype = energyShift >= 0.18 || energyIn >= 0.62 ? "energyWash" : "dropSwap";

  // Shared target grid — don't snap A/B on mismatched source BPMs after stretch.
  const pick = pickDuetWindow(a, b, bpm);
  params.blendDurationSec = pick.blendSec;
  params.cueASec = snapToBar(pick.cueA, bpm);
  params.cueBSec = snapMixIn(pick.cueB, bpm);
  params.bassSwapAt = pick.bassSwapAt;
  params.handoffAt = pick.handoffAt;
  params.incomingVolumeLag = Math.min(0.16, Math.max(0.07, 0.85 / Math.max(4, pick.blendSec)));

  const energyClash = Math.min(
    energyMean(a, params.cueASec, pick.blendSec * 0.5),
    energyMean(b, params.cueBSec, pick.blendSec * 0.5)
  );
  params.bassDepth = energyClash >= 0.55 ? 1.1 : energyClash >= 0.4 ? 1.02 : 0.94;

  const vocalOut = vocalLevelNear(a, params.cueASec, Math.min(12, pick.blendSec));
  const vocalIn = vocalLevelNear(b, params.cueBSec, Math.min(12, pick.blendSec));

  const dsp = defaultDsp();
  dsp.mashupMode = ONE_BAR_DUET_MODE;
  // A = vocal isolate · B = full mix → dual vocals over B instrumental only.
  const pitched = Math.abs(params.pitchCentsB) >= 80;
  const vocalIsolate =
    pick.bothHot >= 0.45 ? 0.95 : pick.bothHot >= 0.28 ? 0.9 : vocalOut >= 0.25 ? 0.86 : 0.8;
  // When we pitch B hard, duck A a touch so the shifted lead owns the ear.
  dsp.instrAPeak = 0;
  dsp.instrAAt = Math.min(0.16, Math.max(0.05, params.incomingVolumeLag));
  dsp.vocalAPeak = pitched ? Math.min(0.9, vocalIsolate) : vocalIsolate;
  dsp.bakeVocalA = true;
  dsp.bakeStems = true;
  dsp.instrBPeak = 0;
  dsp.instrBUntil = 0;
  dsp.vocalBPeak = 0;
  dsp.vocalBAt = 0;
  dsp.vocalDuckBDb = pick.bothHot >= 0.45 ? -7 : pick.bothHot >= 0.3 ? -5.5 : -4;
  // Audible FX — previous Duet buried LPF/echo under the noise floor.
  dsp.lpfBPeak = params.archetype === "energyWash" ? 0.62 : 0.5;
  dsp.hpfAPeak = 0.88;
  dsp.echoAPeak = params.archetype === "energyWash" ? 0.48 : 0.4;
  dsp.bakeInstrA = false;
  dsp.bakeInstrB = false;
  dsp.bakeVocalB = false;
  dsp.sidechainA = Math.min(0.32, 0.12 + pick.bothHot * 0.22);
  dsp.dualLayerPeak = Math.max(0.78, pick.aDuck);
  dsp.guardVocalOut = vocalOut;
  dsp.guardVocalIn = vocalIn;
  params.outgoingVolumeHold = pitched
    ? Math.max(0.72, Math.min(0.84, pick.aDuck))
    : Math.max(0.78, Math.min(0.9, pick.aDuck + 0.1));

  const stretchNote = `Time-stretch · A×${tempo.rateA.toFixed(3)} B×${tempo.rateB.toFixed(3)} → ${Math.round(bpm)} BPM`;
  const keyNote = params.pitchCentsB
    ? `Camelot ${params.pitchCentsB >= 0 ? "+" : ""}${params.pitchCentsB | 0}¢ · ${harmonic.description}`
    : harmonic.description;

  dsp.decisions = [
    `Modern Duet · ${pick.bars} bars / ${pick.beats} beats / ${pick.blendSec.toFixed(1)}s`,
    pick.reason,
    `A vocal isolate ${Math.round((dsp.vocalAPeak || 0) * 100)}% (bake + live)`,
    `B full mix · only B instrumental under dual vocals`,
    `A vol hold @${params.outgoingVolumeHold.toFixed(2)} · B mid-duck ${dsp.vocalDuckBDb} dB`,
    `ONE BASS depth ${params.bassDepth.toFixed(2)} @${(params.bassSwapAt * 100) | 0}%`,
    `FX · LPF invite ${dsp.lpfBPeak.toFixed(2)} · HPF LAND ${dsp.hpfAPeak.toFixed(2)} · echo ${dsp.echoAPeak.toFixed(2)}`,
    stretchNote,
    keyNote,
    `cueA ${params.cueASec.toFixed(1)}s · cueB ${params.cueBSec.toFixed(1)}s · handoff ${(params.handoffAt * 100) | 0}%`,
    a.reason ? `A cue · ${a.reason}` : "A cue · mixOut",
    b.reason ? `B cue · ${b.reason}` : "B cue · mixIn",
  ];
  params.dsp = dsp;

  let plan: AIMixPlan = {
    params,
    profileA: a,
    profileB: b,
    reason: "Modern Adaptive Phrase Duet",
    story: `DUET · ${pick.bars} bars · vocal A + vocal B · instr B · LAND`,
    archetype: params.archetype,
    transitionType: params.archetype === "energyWash" ? "filterSweep" : "eqBlend",
    beatmatched: true,
    processing: [
      "Modern Phrase Duet",
      "Beatmatch + Camelot required (else Automix fallback)",
      "A acapella over B full mix",
      "LPF invite → STACK → ONE BASS → HPF/echo LAND",
      ...dsp.decisions,
    ],
    critic: critiqueDuetPlan(
      params,
      `vocal stack · ${pick.bars} bars (${pick.blendSec.toFixed(1)}s)`,
      bpm,
      true,
      true
    ),
    vocalOut,
    vocalIn,
  };

  plan = applyDuetPremiumLand(plan);
  plan = {
    ...plan,
    critic: critiqueDuetPlan(
      plan.params,
      `vocal stack · ${pick.bars} bars (${plan.params.blendDurationSec.toFixed(1)}s)`,
      bpm,
      true,
      true
    ),
  };
  return plan;
}

function energyMean(profile: TrackAIProfile, from: number, len: number): number {
  if (len <= 0.05 || !profile.energy?.length) return 0.5;
  const i0 = Math.max(0, Math.floor(from / HOP));
  const i1 = Math.min(profile.energy.length, Math.ceil((from + len) / HOP));
  if (i1 <= i0) return 0.5;
  let s = 0;
  for (let i = i0; i < i1; i++) s += profile.energy[i]!;
  return s / (i1 - i0);
}

/** Bar-snap handoff/bass + keep A vocal bake; preserve audible LAND FX. */
function applyDuetPremiumLand(plan: AIMixPlan): AIMixPlan {
  const params = plan.params;
  const bpm = params.targetBPM > 30 ? params.targetBPM : plan.profileA.bpm || 120;
  const landAt = Math.min(
    0.7,
    snapProgressToBar(params.handoffAt, params.blendDurationSec, bpm, 1)
  );
  params.handoffAt = landAt;
  params.bassSwapAt = Math.max(
    0.14,
    Math.min(
      landAt - 0.1,
      snapProgressToBar(params.bassSwapAt, params.blendDurationSec, bpm, 1)
    )
  );
  params.dsp.hpfAPeak = Math.max(0.82, params.dsp.hpfAPeak || 0.82);
  // Don't crush echo — previous cap at 0.28 made LAND feel dry vs Automix.
  params.dsp.echoAPeak = Math.max(0.36, Math.min(0.55, params.dsp.echoAPeak || 0.4));
  params.dsp.lpfBPeak = Math.max(0.45, Math.min(0.7, params.dsp.lpfBPeak || 0.5));
  params.dsp.bakeVocalA = true;
  params.dsp.bakeStems = true;
  params.dsp.bakeInstrA = false;
  params.dsp.bakeInstrB = false;
  params.dsp.bakeVocalB = false;
  params.dsp.instrAPeak = 0;
  params.dsp.vocalAPeak = Math.max(0.8, params.dsp.vocalAPeak || 0.88);
  params.outgoingVolumeHold = Math.max(0.72, params.outgoingVolumeHold || 0.8);
  params.dsp.decisions = [
    ...params.dsp.decisions,
    `Premium Duet LAND @${((landAt * 100) | 0)}% · bar-snap · HPF ${params.dsp.hpfAPeak.toFixed(2)} · echo ${params.dsp.echoAPeak.toFixed(2)}`,
  ];
  return {
    ...plan,
    params,
    story: `${plan.story} → LAND @${((landAt * 100) | 0)}%`,
    processing: [
      ...plan.processing,
      `Premium Duet LAND: A acapella · LPF invite · HPF/echo exit · bar-snap`,
    ],
  };
}

/**
 * Modern Duet volumes: invite → vocal stack (A stays strong) → LAND A out.
 * `outgoingVolumeHold` is A's dual level (≈0.78…0.9).
 */
export function oneBarDuetVolumes(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const handoff = Math.min(0.72, Math.max(0.52, params.handoffAt));
  const invite = Math.min(0.14, Math.max(0.05, params.incomingVolumeLag || 0.08));
  const aDual = Math.min(0.92, Math.max(0.72, params.outgoingVolumeHold || 0.82));
  const landEnd = 0.94;

  let outgoing: number;
  if (p <= invite) outgoing = 1;
  else if (p <= handoff) {
    const t = (p - invite) / Math.max(0.001, handoff - invite);
    outgoing = 1 - t * (1 - aDual);
  } else if (p <= landEnd) {
    outgoing = aDual * (1 - (p - handoff) / Math.max(0.1, landEnd - handoff));
  } else outgoing = 0;

  let incoming: number;
  if (p <= invite) incoming = (p / invite) * 0.78;
  else if (p < handoff) {
    const t = (p - invite) / Math.max(0.001, handoff - invite);
    incoming = 0.78 + 0.22 * t;
  } else incoming = 1;

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
  if (p < handoff - 0.05) return "DUET STACK";
  if (p < handoff + 0.08) return "DUET LAND";
  return "LAND";
}
