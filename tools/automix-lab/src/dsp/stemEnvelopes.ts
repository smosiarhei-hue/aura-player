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

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

/** Zero-slope segment — same join rule as the volume envelopes. */
function seg(p: number, a: number, b: number, y0: number, y1: number): number {
  if (!(b > a + 1e-5)) return p < b ? y0 : y1;
  if (p <= a) return y0;
  if (p >= b) return y1;
  return y0 + (y1 - y0) * smoothstep((p - a) / (b - a));
}

export type StemFxAt = {
  instrumentalA: number;
  /** Early: cut B vocal so it doesn’t stack on A. */
  instrumentalB: number;
  vocalB: number;
  /** Modern Duet: isolate A lead (kill A instruments). */
  vocalA: number;
  hpfA: number;
  lpfB: number;
  echoA: number;
  vocalDuckBDb: number;
};

export function stemFxAt(p: number, params: MashupParams): StemFxAt {
  const dsp = params.dsp;
  const bassAt = clamp(params.bassSwapAt, 0.12, 0.7);
  const handoff = clamp(params.handoffAt, Math.min(0.8, bassAt + 0.08), 0.86);
  const relay = dsp.mashupMode === "acapellaDrop";
  const safe = dsp.mashupMode === "safeExit";
  const instrPeak = clamp(dsp.instrAPeak, 0, 1);
  const instrAt = clamp(dsp.instrAAt, 0.04, 0.7);
  const duet = dsp.mashupMode === "oneBarDuet";

  // Modern Duet: A becomes an acapella over B's full mix (instr + vocal).
  const vocalAPeak = clamp(dsp.vocalAPeak || 0, 0, 1);
  let vocalA = 0;
  if (duet && vocalAPeak > 0.02) {
    const rise = seg(p, 0, Math.min(0.18, Math.max(0.04, instrAt)), 0, vocalAPeak);
    const atHandoff = seg(handoff, 0, Math.min(0.18, Math.max(0.04, instrAt)), 0, vocalAPeak);
    vocalA =
      p <= handoff
        ? rise
        : seg(p, handoff, Math.min(0.96, handoff + 0.2), atHandoff, 0);
  }

  // Relay keeps A's lead carved through LAND. Other modes may ease the carve
  // only after the exit — never snap it back on (that reopens a second vocal).
  // Duet never uses instrumentalA (that would kill the vocal we want to keep).
  let instrumentalA = 0;
  if (instrPeak > 0.02 && !safe && !duet) {
    const risen = seg(p, 0, instrAt, 0, instrPeak);
    if (relay || p <= handoff) instrumentalA = risen;
    else {
      const atHandoff = seg(handoff, 0, instrAt, 0, instrPeak);
      instrumentalA = seg(p, handoff, 1, atHandoff, atHandoff * 0.65);
    }
  }

  const instrBPeak = clamp(dsp.instrBPeak, 0, 1);
  const vocalAt = clamp(Math.max(dsp.vocalBAt, relay ? instrAt : 0), 0.03, 0.85);
  const instrBUntil = clamp(Math.max(dsp.instrBUntil, vocalAt), 0.04, 0.9);
  const releaseEnd = Math.min(0.96, instrBUntil + 0.22);
  let instrumentalB = 0;
  if (instrBPeak > 0.02) {
    const released = instrBPeak * (1 - seg(p, instrBUntil, releaseEnd, 0, 1));
    if (relay && instrBPeak >= 0.4) {
      // Smooth ONE VOCAL gate: B stays instrumental until A is a bed and vocalBAt.
      const aReady = seg(p, Math.max(0, instrAt - 0.06), instrAt + 0.04, 0, 1);
      const vReady = seg(p, vocalAt, Math.min(0.94, vocalAt + 0.16), 0, 1);
      const open = Math.min(aReady, vReady);
      instrumentalB = instrBPeak * (1 - open) + released * open;
    } else {
      instrumentalB = released;
    }
  }

  const vocalPeak = clamp(dsp.vocalBPeak, 0, 1);
  let vocalB = 0;
  if (vocalPeak > 0.02) {
    const openAt = safe ? handoff : vocalAt;
    const opened = seg(p, openAt, Math.max(openAt + 0.1, Math.min(0.92, handoff)), 0, vocalPeak);
    // Follow the instrumental release — no hard mute that clicks when it crosses 0.08.
    const allow = 1 - seg(instrumentalB, 0.02, Math.max(0.28, instrBPeak || 0.28), 0, 1);
    vocalB = opened * allow;
  }

  // HPF only on the LAND exit. Early HPF muffles the instrumental bed.
  const hpfPeak = clamp(dsp.hpfAPeak, 0, 1);
  const hpfStart = safe ? Math.max(0.12, handoff - 0.04) : handoff;
  const hpfEnd = Math.min(0.96, Math.max(hpfStart + 0.14, Math.min(0.9, hpfStart + 0.26)));
  const hpfA = hpfPeak > 0.02 ? hpfPeak * seg(p, hpfStart, hpfEnd, 0, 1) : 0;

  // Soft LPF invite. Duet keeps the muff longer so the filter is actually heard.
  const lpfPeak = Math.min(duet ? 0.7 : 0.55, Math.max(0, dsp.lpfBPeak));
  const lpfEnd = duet
    ? Math.max(0.1, Math.min(Math.max(bassAt, handoff * 0.55), handoff - 0.05))
    : Math.max(0.06, Math.min(bassAt, handoff));
  const lpfB = lpfPeak * (1 - seg(p, 0, lpfEnd, 0, 1));

  const echoPeak = clamp(dsp.echoAPeak, 0, 1);
  let echoA = 0;
  if (echoPeak > 0.02) {
    const echoStart =
      params.archetype === "echoOut" || safe
        ? Math.max(0.08, holdFrac(params) * 0.4)
        : duet
          ? Math.max(bassAt * 0.85, handoff - 0.16)
          : Math.max(bassAt, handoff - 0.1);
    const echoTop = clamp(
      Math.max(echoStart + 0.06, safe ? handoff : duet ? handoff + 0.04 : handoff + 0.02),
      echoStart + 0.04,
      0.82
    );
    const echoDie = Math.min(0.92, Math.max(echoTop + (duet ? 0.14 : 0.1), duet ? 0.86 : 0.84));
    echoA =
      p <= echoTop
        ? echoPeak * seg(p, echoStart, echoTop, 0, 1)
        : echoPeak * (1 - seg(p, echoTop, echoDie, 0, 1));
  }

  const duckPeak = Math.min(0, dsp.vocalDuckBDb);
  // Duet: hold soft B mid-duck through the vocal stack, then release at LAND.
  // AutoMix: duck only while B is still gated instrumental.
  const duckUntil = duet
    ? Math.max(0.45, handoff)
    : Math.max(instrBUntil, vocalAt);
  const vocalDuckBDb = duckPeak * (1 - seg(p, duckUntil, Math.min(0.95, duckUntil + 0.16), 0, 1));

  return {
    instrumentalA,
    instrumentalB,
    vocalB,
    vocalA,
    hpfA,
    lpfB,
    echoA,
    vocalDuckBDb,
  };
}
