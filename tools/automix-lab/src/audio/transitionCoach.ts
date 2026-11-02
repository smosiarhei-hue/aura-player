/**
 * Transition Coach — logging instrument that scores live mashups and learns.
 *
 * If a transition fails ideal DJ gates, it nudges persistent offsets
 * (`.mix-coach.json` via API). Next plans absorb the deltas — small code-path
 * improvements without rewriting the whole engine by hand.
 */

import {
  volumesAt,
  bassGainDbAt,
  playbackRatesAt,
  pitchCentsAt,
  type MashupParams,
} from "./envelopes";
import { stemFxAt } from "../dsp/stemEnvelopes";

export { bakedLeadKill } from "./envelopes";

export type CoachOffsets = {
  /** Earlier A carve (subtract from instrAAt). */
  earlierCarve: number;
  /** Later B vocal open (add to vocalBAt). */
  laterVocalOpen: number;
  /** Earlier bass swap (subtract from bassSwapAt). */
  earlierBass: number;
  /** Deeper bass kill (add to bassDepth). */
  deeperBass: number;
  /** Quieter A dual floor via outgoingVolumeHold reduction. */
  quieterDualA: number;
  /** Stronger LAND HPF. */
  landHpf: number;
  /** Cap echo on mashup peak. */
  echoCap: number;
  /**
   * Shift Automix cueA (seconds). Negative = start mashup earlier
   * (more outro room / leave singing earlier).
   */
  cueShiftSec: number;
  /** Sessions that contributed. */
  samples: number;
  /** Rolling average score 0…100. */
  avgScore: number;
  updatedAt: string;
};

export const DEFAULT_OFFSETS: CoachOffsets = {
  earlierCarve: 0,
  laterVocalOpen: 0,
  earlierBass: 0,
  deeperBass: 0,
  quieterDualA: 0,
  landHpf: 0,
  echoCap: 0,
  cueShiftSec: 0,
  samples: 0,
  avgScore: 100,
  updatedAt: new Date(0).toISOString(),
};

export type MeterPoint = {
  p: number;
  phase: string;
  volA: number;
  volB: number;
  instrA: number;
  instrB: number;
  bassA: number;
  bassB: number;
  hpfA?: number;
  echoA?: number;
  rateB?: number;
  pitchB?: number;
};

export type CoachGate = {
  id: string;
  ok: boolean;
  detail: string;
  /** Suggested offset key + delta when !ok. */
  nudge?: { key: keyof CoachOffsets; delta: number };
};

export type CoachReport = {
  ok: boolean;
  score: number;
  gates: CoachGate[];
  mode: string;
  story: string;
  tweaks: string[];
};

const CLAMP = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/**
 * Score a realtime meter trail against ideal mashup grammar.
 */
export function scoreTransition(
  trail: MeterPoint[],
  opts: {
    mode: string;
    handoffAt: number;
    vocalBAt: number;
    instrAAt: number;
    bassSwapAt: number;
    /**
     * True only when A will be baked with leadKill.
     * A high instr envelope without that bake is still a singing lead.
     */
    nuclearCarve?: boolean;
    /**
     * Measured vocal at the outgoing cue is already a bed (no second lead to carve).
     * Overlap of the two faders is the instrumental bed, not dual vocal.
     */
    naturalBed?: boolean;
  }
): CoachReport {
  const gates: CoachGate[] = [];
  const mode = opts.mode || "unknown";
  const safe = mode === "safeExit";
  const relay = mode === "acapellaDrop";
  const duet = mode === "oneBarDuet";

  if (!trail.length) {
    return {
      ok: false,
      score: 0,
      gates: [{ id: "samples", ok: false, detail: "no meter samples" }],
      mode,
      story: "no data",
      tweaks: [],
    };
  }

  // Modern Duet: dual vocals intentional; A vocal isolate; ONE BASS; LAND early.
  if (duet) {
    const handoff = Math.max(0.45, opts.handoffAt || 0.65);
    const bassAt = Math.max(0.1, opts.bassSwapAt || 0.28);
    const mid = trail.filter((s) => s.p > 0.12 && s.p < handoff - 0.02);
    const dualOk =
      mid.length >= 4 &&
      mid.some((s) => s.volA > 0.55 && s.volB > 0.55);
    gates.push({
      id: "duetDual",
      ok: dualOk,
      detail: dualOk ? "vocal stack present" : "no audible dual vocals",
    });
    // A must stay strong (acapella), B owns the bed — both loud is correct.
    const stackBalance =
      mid.length < 4 ||
      mid.filter((s) => s.volA >= 0.55 && s.volB >= 0.65).length >= mid.length * 0.45;
    gates.push({
      id: "duetStack",
      ok: stackBalance,
      detail: stackBalance ? "A vocal + B full balanced" : "stack levels weak",
    });
    // Vocal isolate: instrA meter carries vocalA amount for duet trails.
    const vocalIso =
      mid.length < 3 ||
      mid.filter((s) => s.instrA >= 0.55 || s.volA >= 0.7).length >= mid.length * 0.4;
    gates.push({
      id: "duetVocalA",
      ok: vocalIso,
      detail: vocalIso ? "A vocal isolate active" : "A vocal isolate weak",
    });
    const afterBass = trail.filter(
      (s) => s.p >= bassAt + 0.04 && s.p <= Math.max(handoff, bassAt + 0.18)
    );
    const bassOk =
      afterBass.length >= 3 &&
      afterBass.every((s) => s.bassA <= -8 || s.volA < 0.15);
    gates.push({
      id: "oneBass",
      ok: bassOk,
      detail: bassOk ? "ONE BASS ok" : "A bass hot after swap",
    });
    const land = trail.filter((s) => s.p >= 0.9);
    const landVol =
      land.length >= 2 && land.every((s) => s.volA <= 0.12 && s.volB >= 0.85);
    gates.push({
      id: "landVol",
      ok: landVol,
      detail: landVol ? "LAND volumes ok" : `LAND vol fail n=${land.length}`,
    });
    const settled = trail.filter(
      (s) => s.p >= 0.88 && s.volA <= 0.12 && s.volB >= 0.85
    );
    const landOnTime = handoff <= 0.74 && settled.length >= 2;
    gates.push({
      id: "landTiming",
      ok: landOnTime,
      detail: landOnTime
        ? "LAND on time"
        : `late LAND handoff=${handoff.toFixed(2)} settled=${settled.length}`,
    });
    const passed = gates.filter((g) => g.ok).length;
    const score = Math.round((passed / gates.length) * 100);
    return {
      ok: gates.every((g) => g.ok),
      score,
      gates,
      mode,
      story: `duet · ${score}/100 · ${passed}/${gates.length} gates`,
      tweaks: [],
    };
  }

  const open = Math.max(0.05, opts.vocalBAt || 0.35);
  const aReady = Math.max(0.04, opts.instrAAt || 0.12);
  const handoff = Math.max(open + 0.05, opts.handoffAt || 0.55);
  const bassAt = Math.max(0.1, opts.bassSwapAt || 0.22);

  // Early window: after A carve, before B vocal — A bed, B gated (relay only).
  const early = trail.filter((s) => s.p >= aReady + 0.02 && s.p < open - 0.02);
  if (relay) {
    // A short or empty gap means B opens with the carve — not a leaked lead.
    const aBed =
      early.length < 4 || early.every((s) => s.instrA >= 0.9 || s.volA <= 0.12);
    const bGated =
      early.length < 4 || early.every((s) => s.instrB >= 0.55 || s.volB < 0.35);
    gates.push({
      id: "aBedBeforeB",
      ok: aBed,
      detail: aBed
        ? `A bed early n=${early.length}`
        : `A still hot before B open (n=${early.length})`,
      nudge: aBed ? undefined : { key: "earlierCarve", delta: 0.02 },
    });
    gates.push({
      id: "bGatedEarly",
      ok: bGated,
      detail: bGated ? "B gated early" : "B lead leaked early",
      nudge: bGated ? undefined : { key: "laterVocalOpen", delta: 0.03 },
    });
  } else {
    gates.push({
      id: "aBedBeforeB",
      ok: true,
      detail: safe ? "Safe Exit — no dual relay required" : "non-relay mode",
    });
  }

  // Dual lead: partial carve (instrA 0.7–0.89) still leaves a singing A under dry B.
  // Acapella Drop may treat instrA ≥ 0.9 as silence only after a baked leadKill.
  // Safe Exit is not allowed a couple of stacked samples either.
  const carved = opts.nuclearCarve === true || opts.naturalBed === true;
  const clash = trail.filter(
    (s) =>
      s.p > 0.1 &&
      s.p < 0.9 &&
      !(carved && s.instrA >= 0.9) &&
      (mode === "acapellaDrop" || s.instrA < 0.9) &&
      s.instrB < 0.55 &&
      s.volA > 0.08 &&
      s.volB > 0.42
  );
  const noDual = clash.length === 0;
  gates.push({
    id: "noDualLead",
    ok: noDual,
    detail: noDual ? "no dual lead" : `dual-lead samples=${clash.length}`,
    nudge: noDual
      ? undefined
      : { key: "quieterDualA", delta: 0.04 },
  });
  if (!noDual) {
    gates.push({
      id: "earlierCue",
      ok: false,
      detail: "dual lead → leave A earlier next time",
      nudge: { key: "cueShiftSec", delta: -0.8 },
    });
  }

  // ONE BASS: shared lows in the mid window, or a swap so late there is no owned section.
  const bassOverlap = trail.filter(
    (s) =>
      s.p > 0.1 &&
      s.p < 0.9 &&
      s.bassA > -8 &&
      s.bassB > -8 &&
      s.volA > 0.08 &&
      s.volB > 0.25
  );
  const afterBass = trail.filter((s) => s.p >= bassAt + 0.04 && s.p <= Math.max(handoff, bassAt + 0.16));
  const bassOk =
    bassOverlap.length === 0 &&
    afterBass.length >= 4 &&
    afterBass.every((s) => s.bassA <= -8 || s.volA < 0.1);
  gates.push({
    id: "oneBass",
    ok: bassOk,
    detail: bassOk ? "ONE BASS ok" : "A bass still hot after swap",
    nudge: bassOk ? undefined : { key: "earlierBass", delta: 0.03 },
  });
  if (!bassOk) {
    gates.push({
      id: "deeperBass",
      ok: false,
      detail: "need deeper kill",
      nudge: { key: "deeperBass", delta: 0.05 },
    });
  }

  // LAND: last ~8% — A quiet, B home, rate/pitch natural, HPF up.
  const land = trail.filter((s) => s.p >= 0.92);
  const landVol =
    land.length >= 2 &&
    land.every((s) => s.volA <= 0.12 && s.volB >= 0.85);
  gates.push({
    id: "landVol",
    ok: landVol,
    detail: landVol ? "LAND volumes ok" : `LAND vol fail n=${land.length}`,
    nudge: landVol ? undefined : { key: "quieterDualA", delta: 0.03 },
  });

  const landHpf =
    !relay ||
    land.length < 2 ||
    land.some((s) => (s.hpfA ?? 0) >= 0.35) ||
    land.every((s) => s.volA <= 0.05);
  gates.push({
    id: "landHpf",
    ok: landHpf,
    detail: landHpf ? "LAND HPF/exit ok" : "LAND HPF weak",
    nudge: landHpf ? undefined : { key: "landHpf", delta: 0.08 },
  });

  const landRate =
    land.length < 2 ||
    land.every((s) => Math.abs((s.rateB ?? 1) - 1) < 0.05);
  gates.push({
    id: "landRate",
    ok: landRate,
    detail: landRate ? "B rate natural" : "B rate not settled",
  });

  const landPitch =
    land.length < 2 ||
    land.every((s) => Math.abs(s.pitchB ?? 0) < 15);
  gates.push({
    id: "landPitch",
    ok: landPitch,
    detail: landPitch
      ? "B pitch natural"
      : `B pitch still shifted @LAND (${land.map((s) => (s.pitchB ?? 0).toFixed(0)).join(",")})`,
    // No offset key — fixed by earlier pitch unwind in envelopes; still scores.
  });

  // Late LAND: handoff in the last quarter, or rate/pitch/level still moving at p≥0.9.
  // cueShiftSec moves the phrase earlier so the same window can finish — it does not shrink it.
  const settled = trail.filter(
    (s) =>
      s.p >= 0.9 &&
      s.volA <= 0.12 &&
      s.volB >= 0.85 &&
      Math.abs((s.rateB ?? 1) - 1) < 0.05 &&
      Math.abs(s.pitchB ?? 0) < 15
  );
  const landOnTime = opts.handoffAt <= 0.74 && settled.length >= 2;
  gates.push({
    id: "landTiming",
    ok: landOnTime,
    detail: landOnTime
      ? "LAND on time"
      : `late LAND handoff=${opts.handoffAt.toFixed(2)} settled=${settled.length}`,
    nudge: landOnTime ? undefined : { key: "cueShiftSec", delta: -0.8 },
  });

  // Echo shouldn't stick at end.
  const echoStuck =
    land.length >= 3 && land.every((s) => (s.echoA ?? 0) > 0.45);
  gates.push({
    id: "echoExit",
    ok: !echoStuck,
    detail: echoStuck ? "echo stuck into LAND" : "echo exit ok",
    nudge: echoStuck ? { key: "echoCap", delta: 0.1 } : undefined,
  });

  const passed = gates.filter((g) => g.ok).length;
  const score = Math.round((passed / gates.length) * 100);
  const tweaks = gates
    .filter((g) => !g.ok && g.nudge)
    .map((g) => `${g.nudge!.key}+${g.nudge!.delta}`);

  return {
    ok: gates.every((g) => g.ok),
    score,
    gates,
    mode,
    story: `${mode} · ${score}/100 · ${passed}/${gates.length} gates`,
    tweaks,
  };
}

/**
 * Simulate envelopes along progress (offline train without WebAudio play).
 */
export function simulateTrail(params: MashupParams, steps = 80): MeterPoint[] {
  const out: MeterPoint[] = [];
  for (let i = 0; i < steps; i++) {
    const p = i / (steps - 1);
    const v = volumesAt(p, params);
    const b = bassGainDbAt(p, params);
    const r = playbackRatesAt(p, params);
    const fx = stemFxAt(p, params);
    out.push({
      p,
      phase: p < params.bassSwapAt ? "INVITE" : p < params.handoffAt ? "MASHUP" : "LAND",
      volA: v.outgoing,
      volB: v.incoming,
      instrA:
        params.dsp.mashupMode === "oneBarDuet" ? fx.vocalA : fx.instrumentalA,
      instrB: fx.instrumentalB,
      bassA: b.outgoing,
      bassB: b.incoming,
      hpfA: fx.hpfA,
      echoA: fx.echoA,
      rateB: r.incoming,
      pitchB: pitchCentsAt(p, params),
    });
  }
  return out;
}

/** Apply learned offsets onto a planned MashupParams (mutates + returns). */
export function applyCoachOffsets(
  params: MashupParams,
  raw: Partial<CoachOffsets> | null | undefined
): MashupParams {
  const o = { ...DEFAULT_OFFSETS, ...(raw || {}) };
  if (o.samples <= 0 && !raw) return params;

  params.dsp.instrAAt = CLAMP(params.dsp.instrAAt - o.earlierCarve, 0.04, 0.45);
  params.dsp.vocalBAt = CLAMP(params.dsp.vocalBAt + o.laterVocalOpen, 0.06, 0.75);
  params.bassSwapAt = CLAMP(params.bassSwapAt - o.earlierBass, 0.1, 0.55);
  params.bassDepth = CLAMP(params.bassDepth + o.deeperBass, 0.6, 1.45);
  params.outgoingVolumeHold = CLAMP(
    params.outgoingVolumeHold - o.quieterDualA,
    0.12,
    0.65
  );
  params.dsp.hpfAPeak = CLAMP(params.dsp.hpfAPeak + o.landHpf, 0.2, 1);
  if (o.echoCap > 0) {
    params.dsp.echoAPeak = Math.min(params.dsp.echoAPeak, Math.max(0.1, 0.85 - o.echoCap));
  }
  if (o.cueShiftSec) {
    // Negative = start the same phrase earlier (more outro to land).
    // blendDurationSec is intentionally untouched.
    params.cueASec = Math.max(0, params.cueASec + o.cueShiftSec);
  }
  // Keep handoff after vocal open / bass, but never push LAND into the last quarter.
  params.handoffAt = CLAMP(
    Math.max(params.handoffAt, params.dsp.vocalBAt + 0.08, params.bassSwapAt + 0.1),
    0.34,
    0.72
  );
  params.dsp.decisions = [
    ...params.dsp.decisions,
    `Coach offsets · carve-${o.earlierCarve.toFixed(2)} vocal+${o.laterVocalOpen.toFixed(2)} bass-${o.earlierBass.toFixed(2)} cue${o.cueShiftSec >= 0 ? "+" : ""}${o.cueShiftSec.toFixed(1)}s n=${o.samples}`,
  ];
  return params;
}

/** Merge a failed report into offsets (small steps, capped). */
export function learnFromReport(
  prev: CoachOffsets,
  report: CoachReport
): CoachOffsets {
  const next: CoachOffsets = {
    ...prev,
    samples: prev.samples + 1,
    avgScore:
      prev.samples <= 0
        ? report.score
        : Math.round((prev.avgScore * prev.samples + report.score) / (prev.samples + 1)),
    updatedAt: new Date().toISOString(),
  };

  if (report.ok) return next;

  const caps: Partial<Record<keyof CoachOffsets, { lo: number; hi: number }>> = {
    earlierCarve: { lo: 0, hi: 0.18 },
    laterVocalOpen: { lo: 0, hi: 0.25 },
    earlierBass: { lo: 0, hi: 0.2 },
    deeperBass: { lo: 0, hi: 0.35 },
    quieterDualA: { lo: 0, hi: 0.28 },
    landHpf: { lo: 0, hi: 0.4 },
    echoCap: { lo: 0, hi: 0.45 },
    cueShiftSec: { lo: -8, hi: 4 },
  };

  for (const g of report.gates) {
    if (g.ok || !g.nudge) continue;
    const { key, delta } = g.nudge;
    if (key === "samples" || key === "avgScore" || key === "updatedAt") continue;
    const range = caps[key];
    if (!range) continue;
    const cur = Number(next[key]) || 0;
    (next as Record<string, number | string>)[key] = CLAMP(
      cur + delta,
      range.lo,
      range.hi
    );
  }
  return next;
}
