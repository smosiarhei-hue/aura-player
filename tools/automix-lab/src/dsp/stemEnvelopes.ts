/**
 * Stem + FX envelopes driven by the AI AutoDspRecipe.
 *
 * Modern mashup:
 *   - A instrumental bed under B groove/vocal (dual layer on purpose)
 *   - Never two lead vocals at once
 *   - B vocal opens on mashup peak once A is carved — not only at LAND
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
  const mashupEnd = Math.min(0.94, handoff + 0.2);
  const instrPeak = Math.min(1, Math.max(0, dsp.instrAPeak));
  const instrAt = Math.min(0.7, Math.max(0.04, dsp.instrAAt));
  let instrumentalA = 0;
  if (instrPeak > 0.02) {
    if (p < instrAt) {
      instrumentalA = instrPeak * smoothstep(p / Math.max(0.001, instrAt));
    } else if (p < mashupEnd) {
      // Hold A as instrumental bed through the remix bar.
      instrumentalA = instrPeak;
    } else {
      instrumentalA =
        instrPeak * (1 - 0.45 * smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
    }
  }

  const instrBPeak = Math.min(1, Math.max(0, dsp.instrBPeak));
  const instrBUntil = Math.min(0.9, Math.max(0.05, dsp.instrBUntil));
  // ~0.16 of the blend window ≈ musical phrase of release (not an 80ms gate).
  const instrBRelease = 0.16;
  let instrumentalB = 0;
  if (instrBPeak > 0.02) {
    if (p < instrBUntil) {
      instrumentalB = instrBPeak;
    } else if (p < instrBUntil + instrBRelease) {
      instrumentalB =
        instrBPeak * (1 - smoothstep((p - instrBUntil) / instrBRelease));
    } else {
      instrumentalB = 0;
    }
  }

  const vocalPeak = Math.min(1, Math.max(0, dsp.vocalBPeak));
  const vocalAt = Math.max(
    Math.min(0.85, Math.max(0.03, dsp.vocalBAt)),
    instrBPeak > 0.2 ? instrBUntil : 0
  );
  let vocalB = 0;
  if (vocalPeak > 0.02) {
    if (p < vocalAt) {
      vocalB = 0;
    } else if (p < mashupEnd) {
      vocalB = vocalPeak * smoothstep((p - vocalAt) / Math.max(0.001, mashupEnd - vocalAt));
    } else {
      vocalB =
        vocalPeak * (1 - 0.25 * smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
    }
  }

  if (instrumentalB > 0.08) {
    vocalB = 0;
  }

  // HPF only at LAND — early/mid HPF just muffles the dual layer.
  const hpfPeak = Math.min(1, Math.max(0, dsp.hpfAPeak));
  const hpfA =
    p < handoff ? 0 : hpfPeak * smoothstep((p - handoff) / Math.max(0.001, 1 - handoff));

  // Soft LPF invite only when recipe asks — never a heavy blanket muff.
  const lpfPeak = Math.min(0.55, Math.max(0, dsp.lpfBPeak));
  const lpfB =
    p >= bassAt ? 0 : lpfPeak * (1 - smoothstep(p / Math.max(0.001, bassAt)));

  const echoPeak = Math.min(1, Math.max(0, dsp.echoAPeak));
  let echoA = 0;
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
