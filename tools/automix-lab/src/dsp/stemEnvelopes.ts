/**
 * Stem + FX envelopes for the DJ 5-act mashup story.
 *
 * These drive MidSideStem / FilterSweep / EchoOut amounts over progress 0…1.
 * Goal: A becomes instrumental bed, B brings vocal focus, one bass, clean land.
 */

import type { MashupParams } from "../audio/envelopes";
import { smoothstep } from "../audio/envelopes";

export type StemFxAt = {
  /** A: 0 dry → 1 instrumental (vocal removed). */
  instrumentalA: number;
  /** B: 0 dry → 1 vocal focus (sides ducked). */
  vocalB: number;
  /** A HPF riser 0…1 (LAND). */
  hpfA: number;
  /** B LPF close amount 0…1 (INVITE — opens as progress rises). */
  lpfB: number;
  /** A echo-out 0…1 near handoff→land. */
  echoA: number;
  /** Mid duck dB on B early (vocal pocket until mashup opens). */
  vocalDuckBDb: number;
};

export function stemFxAt(p: number, params: MashupParams): StemFxAt {
  const bassAt = Math.min(0.7, Math.max(0.12, params.bassSwapAt));
  const handoff = Math.min(0.85, Math.max(bassAt + 0.08, params.handoffAt));
  const inviteEnd = bassAt;
  const mashupEnd = Math.min(0.88, handoff + 0.22);

  // A instrumentalize: ramp during INVITE, full through MASHUP, ease off as A exits.
  let instrumentalA = 0;
  if (p < inviteEnd * 0.35) {
    instrumentalA = 0.15 * smoothstep(p / Math.max(0.001, inviteEnd * 0.35));
  } else if (p < handoff) {
    instrumentalA = 0.15 + 0.75 * smoothstep((p - inviteEnd * 0.35) / Math.max(0.001, handoff - inviteEnd * 0.35));
  } else if (p < mashupEnd) {
    instrumentalA = 0.9;
  } else {
    instrumentalA = 0.9 * (1 - smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
  }

  // B vocal focus: rise as B enters, peak at mashup, settle dry on LAND.
  let vocalB = 0;
  if (p < params.incomingVolumeLag) {
    vocalB = 0.25 * smoothstep(p / Math.max(0.001, params.incomingVolumeLag));
  } else if (p < handoff) {
    vocalB =
      0.25 +
      0.55 *
        smoothstep(
          (p - params.incomingVolumeLag) /
            Math.max(0.001, handoff - params.incomingVolumeLag)
        );
  } else if (p < mashupEnd) {
    vocalB = 0.8;
  } else {
    vocalB = 0.8 - 0.55 * smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd));
  }

  // HPF on A after handoff (LAND riser).
  const hpfA =
    p < handoff
      ? 0
      : smoothstep((p - handoff) / Math.max(0.001, 1 - handoff));

  // LPF on B: closed at invite start, open by ONE BASS.
  const lpfB =
    p >= inviteEnd
      ? 0
      : 1 - smoothstep(p / Math.max(0.001, inviteEnd));

  // Echo-out on A: swell into handoff, ring through early LAND.
  let echoA = 0;
  const echoStart = Math.max(bassAt, handoff - 0.12);
  if (p >= echoStart && p < mashupEnd) {
    echoA = 0.55 * smoothstep((p - echoStart) / Math.max(0.001, mashupEnd - echoStart));
  } else if (p >= mashupEnd) {
    echoA = 0.55 * (1 - smoothstep((p - mashupEnd) / Math.max(0.001, 1 - mashupEnd)));
  }

  // Vocal pocket: duck B mid until mashup opens ( DualDeck vocalDucking feel ).
  const duckUntil = Math.max(inviteEnd, handoff * 0.85);
  const vocalDuckBDb =
    p < duckUntil ? -6 * (1 - smoothstep(p / Math.max(0.001, duckUntil))) : 0;

  return {
    instrumentalA,
    vocalB,
    hpfA,
    lpfB,
    echoA,
    vocalDuckBDb,
  };
}
