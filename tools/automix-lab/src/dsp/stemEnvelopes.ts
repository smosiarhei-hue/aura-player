/**
 * Stem + FX envelopes driven by the AI AutoDspRecipe.
 *
 * ONE VOCAL RULE:
 *   - Never two lead vocals at once.
 *   - If A still sings → instrumentalize A and/or keep B instrumental until A is a bed.
 *   - If A outro is already instrumental → invite B vocal early (Apple mashup).
 */

import type { MashupParams } from "../audio/envelopes";
import { smoothstep } from "../audio/envelopes";

function holdFrac(params: MashupParams): number {
  return Math.min(0.72, Math.max(0.12, params.outgoingVolumeHold));
}

export type StemFxAt = {
  instrumentalA: number;
  /** Early: cut B vocal so it doesn’t stack on A. */
  instrumentalB: number;
  vocalB: number;
  hpfA: number;
  lpfB: number;
  echoA: number;
  vocalDuckBDb: number;
};

export function stemFxAt(p: number, params: MashupParams): StemFxAt {
  const dsp = params.dsp;
  const bassAt = Math.min(0.7, Math.max(0.12, params.bassSwapAt));
  const handoff = Math.min(0.85, Math.max(bassAt + 0.08, params.handoffAt));
  const mashupEnd = Math.min(0.92, handoff + 0.22);

  const instrPeak = Math.min(1, Math.max(0, dsp.instrAPeak));
  const instrAt = Math.min(0.7, Math.max(0.05, dsp.instrAAt));
  let instrumentalA = 0;
  if (instrPeak > 0.02) {
    if (p < instrAt) {
      // Reach full cut ASAP so A vocal is gone before B vocal opens.
      instrumentalA = instrPeak * smoothstep(p / Math.max(0.001, instrAt));
    } else if (p < mashupEnd) {
      instrumentalA = instrPeak;
    } else {
      instrumentalA =
        instrPeak * (1 - 0.35 * smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
    }
  }

  // B instrumental gate: full while A owns the vocal, then release.
  const instrBPeak = Math.min(1, Math.max(0, dsp.instrBPeak));
  const instrBUntil = Math.min(0.9, Math.max(0.05, dsp.instrBUntil));
  let instrumentalB = 0;
  if (instrBPeak > 0.02) {
    if (p < instrBUntil) {
      instrumentalB = instrBPeak;
    } else if (p < instrBUntil + 0.1) {
      instrumentalB =
        instrBPeak * (1 - smoothstep((p - instrBUntil) / 0.1));
    } else {
      instrumentalB = 0;
    }
  }

  // B vocal only after instrumental gate releases — and never before handoff on conflict.
  const vocalPeak = Math.min(1, Math.max(0, dsp.vocalBPeak));
  const vocalAt = Math.max(
    Math.min(0.85, Math.max(0.04, dsp.vocalBAt)),
    instrBPeak > 0.2 ? instrBUntil : 0,
    instrBPeak >= 0.5 ? handoff : 0
  );
  let vocalB = 0;
  if (vocalPeak > 0.02) {
    if (p < vocalAt) {
      vocalB = 0; // hard gate — no soft early bleed of B lead
    } else if (p < mashupEnd) {
      vocalB = vocalPeak * smoothstep((p - vocalAt) / Math.max(0.001, mashupEnd - vocalAt));
    } else {
      vocalB =
        vocalPeak * (1 - 0.35 * smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
    }
  }

  // Hard mutual exclusion: any instrumental gate kills B vocalize.
  if (instrumentalB > 0.08) {
    vocalB = 0;
  }

  const hpfPeak = Math.min(1, Math.max(0, dsp.hpfAPeak));
  const hpfA =
    p < handoff ? 0 : hpfPeak * smoothstep((p - handoff) / Math.max(0.001, 1 - handoff));

  const lpfPeak = Math.min(1, Math.max(0, dsp.lpfBPeak));
  const lpfB =
    p >= bassAt ? 0 : lpfPeak * (1 - smoothstep(p / Math.max(0.001, bassAt)));

  const echoPeak = Math.min(1, Math.max(0, dsp.echoAPeak));
  let echoA = 0;
  // Echo Out starts early (INVITE); EQ Blend / Filter Sweep keep it near LAND.
  const echoStart =
    params.archetype === "echoOut"
      ? Math.max(0.08, holdFrac(params) * 0.5)
      : Math.max(bassAt, handoff - 0.14);
  if (echoPeak > 0.02) {
    if (p >= echoStart && p < mashupEnd) {
      echoA = echoPeak * smoothstep((p - echoStart) / Math.max(0.001, mashupEnd - echoStart));
    } else if (p >= mashupEnd) {
      echoA = echoPeak * (1 - smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
    }
  }

  const duckPeak = Math.min(0, dsp.vocalDuckBDb);
  const duckUntil = Math.max(instrBUntil, Math.max(bassAt, vocalAt));
  const vocalDuckBDb =
    p < duckUntil ? duckPeak * (1 - smoothstep(p / Math.max(0.001, duckUntil))) : 0;

  return {
    instrumentalA,
    instrumentalB,
    vocalB,
    hpfA,
    lpfB,
    echoA,
    vocalDuckBDb,
  };
}
