/**
 * Stem + FX envelopes driven by the AI AutoDspRecipe.
 * Peaks / timings come from planAutomix — not hardcoded club presets.
 */

import type { MashupParams } from "../audio/envelopes";
import { smoothstep } from "../audio/envelopes";

export type StemFxAt = {
  instrumentalA: number;
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
  const instrAt = Math.min(0.7, Math.max(0.08, dsp.instrAAt));
  let instrumentalA = 0;
  if (instrPeak > 0.02) {
    if (p < instrAt) {
      instrumentalA = instrPeak * smoothstep(p / Math.max(0.001, instrAt));
    } else if (p < mashupEnd) {
      instrumentalA = instrPeak;
    } else {
      // Keep some instrumental bed while A fades; drop to 0 as A is gone.
      instrumentalA = instrPeak * (1 - 0.35 * smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
    }
  }

  const vocalPeak = Math.min(1, Math.max(0, dsp.vocalBPeak));
  const vocalAt = Math.min(0.65, Math.max(0.04, dsp.vocalBAt));
  let vocalB = 0;
  if (vocalPeak > 0.02) {
    if (p < vocalAt) {
      vocalB = vocalPeak * 0.35 * smoothstep(p / Math.max(0.001, vocalAt));
    } else if (p < handoff) {
      vocalB =
        vocalPeak * 0.35 +
        vocalPeak * 0.65 * smoothstep((p - vocalAt) / Math.max(0.001, handoff - vocalAt));
    } else if (p < mashupEnd) {
      vocalB = vocalPeak;
    } else {
      // Settle toward dry once B owns the track.
      vocalB = vocalPeak * (1 - 0.7 * smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
    }
  }

  const hpfPeak = Math.min(1, Math.max(0, dsp.hpfAPeak));
  const hpfA =
    p < handoff ? 0 : hpfPeak * smoothstep((p - handoff) / Math.max(0.001, 1 - handoff));

  const lpfPeak = Math.min(1, Math.max(0, dsp.lpfBPeak));
  const lpfB =
    p >= bassAt ? 0 : lpfPeak * (1 - smoothstep(p / Math.max(0.001, bassAt)));

  const echoPeak = Math.min(1, Math.max(0, dsp.echoAPeak));
  let echoA = 0;
  const echoStart = Math.max(bassAt, handoff - 0.14);
  if (echoPeak > 0.02) {
    if (p >= echoStart && p < mashupEnd) {
      echoA = echoPeak * smoothstep((p - echoStart) / Math.max(0.001, mashupEnd - echoStart));
    } else if (p >= mashupEnd) {
      echoA = echoPeak * (1 - smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
    }
  }

  const duckPeak = Math.min(0, dsp.vocalDuckBDb); // negative dB
  const duckUntil = Math.max(bassAt, handoff * 0.85);
  const vocalDuckBDb =
    p < duckUntil ? duckPeak * (1 - smoothstep(p / Math.max(0.001, duckUntil))) : 0;

  return {
    instrumentalA,
    vocalB,
    hpfA,
    lpfB,
    echoA,
    vocalDuckBDb,
  };
}
