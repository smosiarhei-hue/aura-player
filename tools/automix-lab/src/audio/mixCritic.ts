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
import {
  bakedLeadKill,
  bassGainDbAt,
  pitchCentsAt,
  playbackRatesAt,
  volumesAt,
  type MashupParams,
} from "./envelopes";
import type { TransitionType } from "./transitionPlanner";

/**
 * Budgets aligned to OpenSonic verify.py (vocals ≤1.0 beat, bass ≤1.25) with a
 * small Mid/Side residual allowance — no Demucs stems in Lab, so not byte-identical.
 * Fail → Vocal Safe / Bass Surgeon. Never trust soft Mid/Side as a free pass.
 */
export const VOCAL_CLASH_MAX_BEATS = 1.5;
export const VOCAL_CLASH_MAX_FRAC = 0.08;
/** OpenSonic bass budget is 1.25 beats; Lab allows a short handoff. */
export const BASS_CLASH_MAX_BEATS = 1.5;
export const BASS_CLASH_MAX_FRAC = 0.12;
const LEAD_ON = 0.25;
/** Both lows louder than this (dB) count as shared bass. */
const BASS_HOT_DB = -8;
const STEPS = 64;

export type MixCriticGate = {
  id: "vocalClash" | "bassClash" | "harmonic" | "tempo" | "land";
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
  bassClashBeats: number;
  fixes: string[];
  mode:
    | "pass"
    | "vocalSafe"
    | "bassSurgeon"
    | "vocalSafe+bassSurgeon"
    | "earlierLand"
    | "vocalSafe+earlierLand"
    | "bassSurgeon+earlierLand"
    | "vocalSafe+bassSurgeon+earlierLand";
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
 * Estimate lead audibility after the carve the engine will actually run.
 * Soft Mid/Side leaves formants — a high instr envelope is not silence.
 * Baked leadKill (whole slice) is the only path that may claim a small residual.
 */
function leadA(vocalOut: number, instrA: number, bakedKill: boolean): number {
  if (bakedKill) return clamp01(vocalOut * 0.07);
  const kill = 0.58;
  const leak = 0.08;
  return clamp01(vocalOut * (1 - instrA * kill) + vocalOut * leak * (1 - instrA));
}

function leadB(vocalIn: number, instrB: number, vocalFocus: number): number {
  // Full gate: thin residual. Partial tuck still leaks the lead.
  if (instrB >= 0.85) return clamp01(vocalIn * (1 - instrB) * 0.45);
  if (instrB > 0.08) return clamp01(vocalIn * (1 - instrB * 0.55));
  return clamp01(vocalIn * Math.max(vocalFocus, 1 - instrB));
}

export function critiqueMix(input: MixCriticInput): MixCriticReport {
  const { params, vocalOut, vocalIn, bpm, transitionType, harmonicOk, beatmatched } = input;
  // One-Bar Duet *is* dual lead for ~1 bar — do not Vocal Safe it away.
  if (params.dsp.mashupMode === "oneBarDuet") {
    const blendSec = Math.max(1, params.blendDurationSec);
    const spb = 60 / Math.max(60, bpm);
    return {
      ok: true,
      score: 100,
      gates: [
        {
          id: "vocalClash",
          ok: true,
          label: "DUET VOCAL",
          detail: `intentional dual lead · ${blendSec.toFixed(2)}s (~${(blendSec / spb).toFixed(1)} beat)`,
        },
        {
          id: "bassClash",
          ok: true,
          label: "ONE BASS",
          detail: "short bar · mid swap",
        },
        {
          id: "harmonic",
          ok: true,
          label: "Key / Camelot",
          detail: harmonicOk ? "compatible or pitch-compensated" : "duet tolerates brief clash",
        },
        {
          id: "tempo",
          ok: true,
          label: "Tempo lock",
          detail: beatmatched ? "beatmatched" : "duet grid",
        },
        {
          id: "land",
          ok: params.handoffAt <= 0.78,
          label: "LAND",
          detail: params.handoffAt <= 0.78 ? "LAND to B" : `late handoff @${(params.handoffAt * 100) | 0}%`,
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
  const blendSec = Math.max(1, params.blendDurationSec);
  const spb = 60 / Math.max(60, bpm); // seconds per beat
  const blendBeats = blendSec / spb;

  const bakedKill = bakedLeadKill(params.dsp);
  let vocalBoth = 0;
  let bassBoth = 0;
  // Audible fader → full lead credit by ~0.18. A whisper (≤0.05) is not a second vocal.
  const fader = (vol: number) => (vol <= 0.05 ? 0 : Math.min(1, vol / 0.18));
  for (let i = 0; i < STEPS; i++) {
    const p = (i + 0.5) / STEPS;
    const fx = stemFxAt(p, params);
    const vols = volumesAt(p, params);
    const aLead = leadA(vocalOut, fx.instrumentalA, bakedKill) * fader(vols.outgoing);
    const bLead = leadB(vocalIn, fx.instrumentalB, fx.vocalB) * fader(vols.incoming);
    if (aLead > LEAD_ON && bLead > LEAD_ON) vocalBoth++;

    const bass = bassGainDbAt(p, params);
    // Real ONE BASS curve — shallow depth never finishes the kill.
    if (
      p > 0.12 &&
      p < 0.88 &&
      vols.outgoing > 0.08 &&
      vols.incoming > 0.2 &&
      bass.outgoing > BASS_HOT_DB &&
      bass.incoming > BASS_HOT_DB
    ) {
      bassBoth++;
    }
  }

  const vocalClashFrac = vocalBoth / STEPS;
  const bassClashFrac = bassBoth / STEPS;
  const vocalClashBeats = vocalClashFrac * blendBeats;
  const bassClashBeats = bassClashFrac * blendBeats;

  const vocalOk =
    vocalClashBeats <= VOCAL_CLASH_MAX_BEATS && vocalClashFrac <= VOCAL_CLASH_MAX_FRAC;
  const bassOk =
    bassClashFrac <= BASS_CLASH_MAX_FRAC && bassClashBeats <= BASS_CLASH_MAX_BEATS;

  // LAND must start with room to settle. A handoff in the last quarter
  // leaves rate, pitch, and A's exit unfinished — that is a late LAND.
  let landDetail = "LAND settles";
  let landOk = params.handoffAt <= 0.74;
  if (!landOk) landDetail = `late handoff @${(params.handoffAt * 100) | 0}%`;
  for (const p of [0.93, 0.97]) {
    const v = volumesAt(p, params);
    const r = playbackRatesAt(p, params);
    const cents = Math.abs(pitchCentsAt(p, params));
    if (v.outgoing > 0.12 || v.incoming < 0.85) {
      landOk = false;
      landDetail = `LAND vol A ${v.outgoing.toFixed(2)} B ${v.incoming.toFixed(2)}`;
    } else if (Math.abs(r.incoming - 1) > 0.045 || Math.abs(r.outgoing - 1) > 0.045) {
      landOk = false;
      landDetail = `LAND rate B ${r.incoming.toFixed(3)}`;
    } else if (cents > 12) {
      landOk = false;
      landDetail = `LAND pitch ${cents.toFixed(0)}¢`;
    }
  }
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
        ? `overlap ${bassClashBeats.toFixed(1)} beat · ${(bassClashFrac * 100) | 0}%`
        : `overlap ${bassClashBeats.toFixed(1)} beat · ${(bassClashFrac * 100) | 0}% (budget ${BASS_CLASH_MAX_BEATS} beat / ${(BASS_CLASH_MAX_FRAC * 100) | 0}%)`,
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
    {
      id: "land",
      ok: landOk,
      label: "LAND",
      detail: landDetail,
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
    bassClashBeats,
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
  const needLand = !report.gates.find((g) => g.id === "land")!.ok;
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
    // Bass Surgeon: earlier swap, but never dig a hollow −20 dB hole.
    input.params.bassSwapAt = Math.max(0.14, Math.min(input.params.bassSwapAt, 0.22));
    input.params.bassDepth = Math.min(1.05, Math.max(input.params.bassDepth, 0.9));
    dsp.decisions = [
      ...dsp.decisions.filter((d) => !d.startsWith("Mix Critic · Bass")),
      "Mix Critic · Bass Surgeon: earlier bass swap (capped depth)",
    ];
    fixes.push("Bass Surgeon");
  }

  if (needLand) {
    // Pull the exit earlier inside the same phrase — never shorten the window.
    input.params.handoffAt = Math.min(input.params.handoffAt, 0.62);
    input.params.outgoingVolumeHold = Math.min(
      input.params.outgoingVolumeHold,
      Math.max(0.16, input.params.handoffAt - 0.14)
    );
    dsp.decisions = [
      ...dsp.decisions.filter((d) => !d.startsWith("Mix Critic · LAND")),
      "Mix Critic · LAND earlier inside the phrase",
    ];
    fixes.push("Earlier LAND");
  }

  const again = critiqueMix(input);
  again.fixes = fixes;
  again.mode = (
    [
      needVocal ? "vocalSafe" : "",
      needBass ? "bassSurgeon" : "",
      needLand ? "earlierLand" : "",
    ]
      .filter(Boolean)
      .join("+") || "pass"
  ) as MixCriticReport["mode"];
  return again;
}

/** Critique then auto-fix once. */
export function runMixCritic(input: MixCriticInput): MixCriticReport {
  const first = critiqueMix(input);
  if (first.ok) return first;
  return applyMixCriticFixes(input, first);
}
