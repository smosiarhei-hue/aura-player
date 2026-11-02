/** Curves + auto-DSP recipe mirrored from Sonivo mashup intent. */

/** Maps TZ transition types onto envelope/DSP presets. */
export type MashupArchetype =
  | "dropSwap" // EQ Blend / Bass Swap
  | "seamlessLoop" // Long Blend
  | "energyWash" // Filter Sweep
  | "echoOut"
  | "cutOnOne"
  | "smartCrossfade";

/**
 * What the AI decides to *do* to the audio — not just volume knobs.
 * Engine reads this and actually processes stems / schedules FX.
 */
export type AutoDspRecipe = {
  /** Peak Mid/Side instrumentalize on A (0…1). High when A outro still has vocals. */
  instrAPeak: number;
  /** When (0…1 progress) A instrumentalize reaches peak. */
  instrAAt: number;
  /**
   * Early instrumentalize on B (0…1) — kills B’s lead vocal while A still sings.
   * One-vocal rule: never stack two leads.
   */
  instrBPeak: number;
  /** Progress where B instrumentalize releases (then vocal B may open). */
  instrBUntil: number;
  /** Peak vocal-focus on B (0…1). */
  vocalBPeak: number;
  /** When B vocal focus opens — must be ≥ instrBUntil when A had vocals. */
  vocalBAt: number;
  /** Early mid-duck on B in dB (negative). Clears space under A vocal. */
  vocalDuckBDb: number;
  /** HPF riser intensity on A at LAND (0…1). */
  hpfAPeak: number;
  /** LPF muffling on B at INVITE start (0…1). */
  lpfBPeak: number;
  /** Echo-out peak on A (0…1). */
  echoAPeak: number;
  /** Offline-bake stems before play (stronger than live Mid/Side alone). */
  bakeStems: boolean;
  /** Bake A as instrumental slice (safe anytime A has outro vocals). */
  bakeInstrA: boolean;
  /**
   * Bake B as instrumental through the dual-layer window (ONE VOCAL conflict).
   * At handoff the engine crossfades into dry/vocal B so LAND has a lead.
   */
  bakeInstrB: boolean;
  /**
   * Bake B as vocal slice — ONLY when A outro is already instrumental.
   * Never bake B vocal for the whole blend if A still sings (would stack leads).
   */
  bakeVocalB: boolean;
  /** Human-readable decisions for UI / preset. */
  decisions: string[];
  /** Modern mashup mode label (acapellaDrop / safeExit / …). */
  mashupMode: string;
  /** Sidechain duck of A under B groove (0…1), applied offline on bake. */
  sidechainA: number;
  /**
   * How loud A stays through the dual-layer window (0…1).
   * Texture bed keeps this high — a low peak plus a lagged incoming deck is a hole.
   */
  dualLayerPeak?: number;
  /**
   * Vocal presence at the cues (0…1). Play/render re-run Mix Critic with these
   * so Vocal Safe / Bass Surgeon still apply after LAND snap or coach offsets.
   */
  guardVocalOut?: number;
  guardVocalIn?: number;
};

/**
 * Nuclear center carve (formant + presence), not a soft Mid/Side tuck.
 * Acapella Drop only when the recipe already asked for a deep bed; any mode
 * at instrAPeak ≥ 0.9 is the same request.
 */
export function wantsLeadKill(dsp: AutoDspRecipe): boolean {
  const peak = dsp.instrAPeak || 0;
  // High peak marks "A is a bed" for the gates. Nuclear carve only when we bake
  // a vocal out — a clean instrumental outro keeps its tone.
  if (!dsp.bakeInstrA && !dsp.bakeStems) return false;
  return (dsp.mashupMode === "acapellaDrop" && peak >= 0.85) || peak >= 0.9;
}

/** True only when that nuclear carve will actually be baked before play. */
export function bakedLeadKill(dsp: AutoDspRecipe): boolean {
  return wantsLeadKill(dsp) && (!!dsp.bakeInstrA || !!dsp.bakeStems) && (dsp.instrAPeak || 0) >= 0.85;
}

export type MashupParams = {
  bassSwapAt: number;
  handoffAt: number;
  outgoingVolumeHold: number;
  incomingVolumeLag: number;
  bassDepth: number;
  rateA: number;
  rateB: number;
  pitchCentsB: number;
  targetBPM: number;
  blendDurationSec: number;
  cueASec: number;
  cueBSec: number;
  archetype: MashupArchetype;
  /** Filled by planAutomix — engine consumes this. */
  dsp: AutoDspRecipe;
};

export const defaultDsp = (): AutoDspRecipe => ({
  instrAPeak: 0.85,
  instrAAt: 0.35,
  instrBPeak: 0,
  instrBUntil: 0.2,
  vocalBPeak: 0.7,
  vocalBAt: 0.2,
  vocalDuckBDb: -5,
  hpfAPeak: 0.85,
  lpfBPeak: 0.7,
  echoAPeak: 0.5,
  bakeStems: true,
  bakeInstrA: true,
  bakeInstrB: false,
  bakeVocalB: false,
  decisions: [],
  mashupMode: "acapellaDrop",
  sidechainA: 0.4,
});

export const defaultParams = (): MashupParams => ({
  bassSwapAt: 0.22,
  handoffAt: 0.52,
  outgoingVolumeHold: 0.48,
  incomingVolumeLag: 0.12,
  bassDepth: 1.1,
  rateA: 1,
  rateB: 1,
  pitchCentsB: 0,
  targetBPM: 0,
  blendDurationSec: 24,
  cueASec: 0,
  cueBSec: 0,
  archetype: "dropSwap",
  dsp: defaultDsp(),
});

export function smoothstep(t: number): number {
  const x = Math.min(1, Math.max(0, t));
  return x * x * (3 - 2 * x);
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

/**
 * Smoothstep between two knots. Slope is 0 at both ends, so adjacent
 * segments meet without a click (value and derivative).
 */
function seg(p: number, a: number, b: number, y0: number, y1: number): number {
  if (!(b > a + 1e-5)) return p < b ? y0 : y1;
  if (p <= a) return y0;
  if (p >= b) return y1;
  return y0 + (y1 - y0) * smoothstep((p - a) / (b - a));
}

/** Where LAND unwinds tempo/pitch. Late handoff cannot finish early. */
function landSettle(params: MashupParams): { settleAt: number; settleBy: number } {
  const lockAt = Math.min(0.22, Math.max(0.08, params.bassSwapAt * 0.6));
  const settleAt = Math.min(0.92, Math.max(lockAt + 0.05, params.handoffAt));
  const settleBy = Math.min(0.985, settleAt + 0.2);
  return { settleAt, settleBy };
}

export function tempoMatch(
  bpmA: number,
  bpmB: number
): { targetBPM: number; rateA: number; rateB: number } | null {
  if (!(bpmA > 30 && bpmB > 30)) return null;
  const direct = bpmA / bpmB;
  if (Math.abs(direct - 1) <= 0.16) {
    return { targetBPM: bpmA, rateA: 1, rateB: direct };
  }
  let b = bpmB;
  if (Math.abs(bpmA - b * 2) < Math.abs(bpmA - b)) b *= 2;
  if (Math.abs(bpmA - b / 2) < Math.abs(bpmA - b)) b /= 2;
  const target = (bpmA + b) / 2;
  const rateA = target / bpmA;
  const rateB = target / b;
  if (Math.max(Math.abs(rateA - 1), Math.abs(rateB - 1)) > 0.16) {
    if (Math.abs(direct - 1) <= 0.16) {
      return { targetBPM: bpmA, rateA: 1, rateB: Math.min(1.16, Math.max(0.84, direct)) };
    }
    return null;
  }
  return {
    targetBPM: target,
    rateA: Math.min(1.16, Math.max(0.84, rateA)),
    rateB: Math.min(1.16, Math.max(0.84, rateB)),
  };
}

/**
 * Texture bed / instrumental wash — equal-power dual layer.
 * A cut that parks B near 0.1 while A's outro is already quieter than the lead
 * opens a hole, then LAND slams in hot. B is audible from the first samples;
 * a long incomingVolumeLag is ignored on purpose.
 */
function textureLayerVolumes(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const handoff = clamp(params.handoffAt, 0.42, 0.82);
  const crafted = params.dsp.dualLayerPeak;
  const peak = clamp(typeof crafted === "number" && crafted > 0.4 ? crafted : 0.88, 0.72, 0.94);
  // Partner of `peak`, still a bed (not a second full lead) until LAND.
  const bed = clamp(Math.sqrt(Math.max(0, 1 - peak * peak)) + 0.22, 0.58, 0.74);
  const lag = 0.05;
  const landEnd = Math.min(0.95, Math.max(handoff + 0.14, 0.9));
  let outgoing = p <= handoff ? seg(p, 0, handoff, 1, peak) : seg(p, handoff, landEnd, peak, 0);
  let incoming =
    p <= lag
      ? seg(p, 0, lag, 0.22, bed)
      : p <= handoff
        ? bed
        : seg(p, handoff, landEnd, bed, 1);
  // prog≈0 must not be two quiet faders. A holds the lead; B is already a bed.
  if (p < 0.08 && outgoing < 0.45 && incoming < 0.4) {
    outgoing = Math.max(outgoing, 0.92);
    incoming = Math.max(incoming, 0.22);
  }
  const pow = Math.hypot(outgoing, incoming);
  if (p < landEnd && pow < 0.9 && pow > 0.05) {
    const s = Math.min(1.25, 0.9 / pow);
    outgoing *= s;
    incoming *= s;
  }
  return {
    outgoing: clamp(outgoing, 0, 1),
    incoming: clamp(incoming, 0, 1),
  };
}

/** Dual-layer mashup volumes — shaped by TZ transition type. */
export function volumesAt(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  // Phrase Duet: B-led dual (A ducked), LAND A out by ~0.92.
  if (params.dsp.mashupMode === "oneBarDuet") {
    const handoff = Math.min(0.72, Math.max(0.52, params.handoffAt));
    const invite = Math.min(0.16, Math.max(0.05, params.incomingVolumeLag || 0.08));
    const aDual = Math.min(0.82, Math.max(0.5, params.outgoingVolumeHold || 0.65));
    const landEnd = 0.92;
    let outgoing: number;
    if (p <= invite) outgoing = 1;
    else if (p <= handoff) {
      const t = (p - invite) / Math.max(0.001, handoff - invite);
      outgoing = 1 - t * (1 - aDual);
    } else if (p <= landEnd) {
      outgoing = aDual * (1 - (p - handoff) / Math.max(0.08, landEnd - handoff));
    } else outgoing = 0;
    let incoming: number;
    if (p <= invite) incoming = (p / invite) * 0.85;
    else if (p < handoff) {
      const t = (p - invite) / Math.max(0.001, handoff - invite);
      incoming = 0.85 + 0.15 * t;
    } else incoming = 1;
    if (p < handoff) {
      const pow = Math.hypot(outgoing, incoming);
      if (pow > 0.05 && pow < 0.85) {
        const s = Math.min(1.08, 0.92 / pow);
        incoming = Math.min(1, incoming * s);
        outgoing = Math.min(aDual + 0.05, outgoing * s);
      }
    }
    return {
      outgoing: clamp(outgoing, 0, 1),
      incoming: clamp(incoming, 0, 1),
    };
  }

  // Safe Exit: A still sings → ONE VOCAL, but this is still AutoMix, not a
  // 1-second blink. Beatmatched phrase: A holds → multi-bar handoff → B home.
  // Never stack two full leads; hypot-normalize so ears don't hear a dip/slam.
  if (params.dsp.mashupMode === "safeExit") {
    const mid = clamp(params.handoffAt, 0.48, 0.7);
    // ~28% of the blend ≈ several bars on a 20–32s Automix window.
    const half = 0.14;
    const a0 = Math.max(0.18, mid - half);
    const a1 = Math.min(0.92, mid + half * 0.55);
    const b0 = Math.max(0.1, a0 - 0.08);
    const b1 = Math.min(0.94, mid + half);
    let outgoing = p <= a0 ? 1 : seg(p, a0, a1, 1, 0);
    let incoming =
      p <= b0
        ? seg(p, 0, b0, 0, 0.22)
        : p <= mid
          ? seg(p, b0, mid, 0.22, 0.58)
          : seg(p, mid, b1, 0.58, 1);
    const pow = Math.hypot(outgoing, incoming);
    if (p < a1 && pow > 0.05 && pow < 0.92) {
      const s = Math.min(1.2, 0.92 / pow);
      outgoing *= s;
      incoming *= s;
    }
    return {
      outgoing: clamp(outgoing, 0, 1),
      incoming: clamp(incoming, 0, 1),
    };
  }

  // Texture / wash: do not use the cut's near-silent incoming park.
  if (
    params.dsp.mashupMode === "textureBed" ||
    params.dsp.mashupMode === "instrumentalWash"
  ) {
    return textureLayerVolumes(p, params);
  }

  // Acapella: B is the lead from the first sample. Parking B near silence
  // while A falls into a breakdown is a multi-second hole, not a crossfade.
  if (params.dsp.mashupMode === "acapellaDrop") {
    const handoff = clamp(params.handoffAt, 0.34, 0.86);
    const hold = clamp(Math.min(params.outgoingVolumeHold || 0.22, 0.24), 0.08, handoff - 0.1);
    const bed = 0.42;
    const guest = 0.88;
    let outgoing = p <= handoff ? seg(p, 0, hold, 1, bed) : seg(p, handoff, 1, bed, 0);
    let incoming = p >= handoff ? 1 : seg(p, 0, handoff, guest, 1);
    const pow = Math.hypot(outgoing, incoming);
    if (p < 0.95 && pow > 0.05 && pow < 0.9) {
      const s = Math.min(1.22, 0.9 / pow);
      outgoing *= s;
      incoming *= s;
    }
    return {
      outgoing: clamp(outgoing, 0, 1),
      incoming: clamp(incoming, 0, 1),
    };
  }

  // Cut on the 1 — last-resort splice, still ~a bar of fade (not a click).
  if (params.archetype === "cutOnOne") {
    const cut = clamp(params.handoffAt, 0.4, 0.72);
    const half = 0.08;
    const a0 = Math.max(0.2, cut - half);
    const a1 = Math.min(0.92, cut + half);
    const pre = Math.min(0.2, Math.max(0.08, a0 - 0.05));
    const incoming =
      p < a0 ? seg(p, 0, pre, 0, 0.14) : seg(p, a0, a1, 0.14, 1);
    return { outgoing: seg(p, a0, a1, 1, 0), incoming };
  }

  const modern = params.dsp.mashupMode === "acapellaDrop";
  const echo = params.archetype === "echoOut";
  let handoff = clamp(params.handoffAt, 0.34, 0.86);
  // Keep a real fade after the hold. Collapsing hold onto handoff used to step A by ~0.5.
  const hold = clamp(params.outgoingVolumeHold, 0.12, handoff - 0.1);
  const lag = clamp(params.incomingVolumeLag, 0.08, Math.max(0.1, handoff - 0.1));

  // Acapella: A stays an audible instrumental bed under B, then exits on LAND.
  // Echo: A stays a little hotter so the delay has a source. Never a whisper-only bed.
  const bed = modern ? 0.38 : echo ? 0.46 : params.archetype === "smartCrossfade" ? 0.34 : 0.44;
  const guest = modern ? 0.7 : echo ? 0.62 : 0.56;

  let outgoing =
    p <= handoff ? seg(p, 0, hold, 1, bed) : seg(p, handoff, 1, bed, 0);
  let incoming =
    p >= handoff
      ? 1
      : p <= lag
        ? seg(p, 0, lag, 0, guest)
        : seg(p, lag, handoff, guest, 1);
  // Equal-power ride through the invite → LAND so levels stay ear-even.
  const landEnd = Math.min(0.96, Math.max(handoff + 0.12, 0.88));
  const pow = Math.hypot(outgoing, incoming);
  if (p < landEnd && pow > 0.05 && pow < 0.9) {
    const s = Math.min(1.22, 0.9 / pow);
    outgoing *= s;
    incoming *= s;
  }
  return {
    outgoing: clamp(outgoing, 0, 1),
    incoming: clamp(incoming, 0, 1),
  };
}

export function bassGainDbAt(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const bassAt = Math.min(0.7, Math.max(0.12, params.bassSwapAt));
  // ONE BASS: dig A fully before B rises — brief quiet handoff, never dual-hot mud.
  // Cap depth so the quiet gap isn't a −20 dB hole.
  const depth = Math.min(1.05, Math.max(0.55, params.bassDepth));
  const killDb = -11 * depth;
  // A is dug by ~70% of bassAt; B starts rising just after that.
  const killA = smoothstep(p / Math.max(0.001, bassAt * 0.7));
  const restoreB = smoothstep(
    (p - bassAt * 0.72) / Math.max(0.001, bassAt * 0.45 + 0.08)
  );
  return {
    outgoing: killDb * killA,
    incoming: killDb * (1 - Math.min(1, Math.max(0, restoreB))),
  };
}

export function playbackRatesAt(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const lockAt = Math.min(0.22, Math.max(0.08, params.bassSwapAt * 0.6));
  const { settleAt, settleBy } = landSettle(params);
  const out =
    p < lockAt
      ? seg(p, 0, lockAt, 1, params.rateA)
      : p < settleAt
        ? params.rateA
        : seg(p, settleAt, settleBy, params.rateA, 1);
  const inn =
    p < lockAt
      ? seg(p, 0, lockAt, 1, params.rateB)
      : p < settleAt
        ? params.rateB
        : seg(p, settleAt, settleBy, params.rateB, 1);
  return { outgoing: out, incoming: inn };
}

export function pitchCentsAt(p: number, params: MashupParams): number {
  const target = params.pitchCentsB;
  if (Math.abs(target) < 0.5) return 0;
  const rampIn = clamp(params.bassSwapAt * 0.65, 0.08, 0.2);
  const { settleAt, settleBy } = landSettle(params);
  const holdEnd = Math.max(rampIn + 0.05, Math.min(settleAt, rampIn + 0.5));
  if (p <= rampIn) return seg(p, 0, rampIn, 0, target);
  if (p <= holdEnd) return target;
  return seg(p, holdEnd, settleBy, target, 0);
}

export function phaseLabel(p: number, params: MashupParams): string {
  if (params.dsp.mashupMode === "oneBarDuet") {
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
  const lockEnd = Math.min(0.18, params.bassSwapAt * 0.65);
  if (p < lockEnd) {
    return params.targetBPM > 30
      ? `LOCK ${Math.round(params.targetBPM)}`
      : "LOCK";
  }
  if (Math.abs(params.pitchCentsB) >= 20 && p < Math.min(0.28, params.bassSwapAt)) {
    const sign = params.pitchCentsB >= 0 ? "+" : "";
    return `KEY ${sign}${Math.round(params.pitchCentsB)}¢`;
  }
  const aReady = Math.max(0.04, params.dsp.instrAAt);
  const bOpen = Math.max(aReady + 0.05, params.dsp.vocalBAt);
  if (params.dsp.mashupMode === "acapellaDrop" && p >= aReady && p < bOpen) {
    return "A INSTR";
  }
  if (params.dsp.mashupMode === "acapellaDrop" && p >= bOpen && p < params.handoffAt) {
    return "B VOCAL";
  }
  if (params.dsp.mashupMode === "safeExit") {
    if (p < params.bassSwapAt) return "INVITE B";
    if (p < params.handoffAt - 0.06) return "ONE BASS";
    if (p < params.handoffAt + 0.12) return "ECHO EXIT";
    return "LAND";
  }
  if (params.archetype === "cutOnOne") {
    if (p < params.handoffAt - 0.05) return "SAFE EXIT";
    if (p < params.handoffAt + 0.08) return "CUT ON 1";
    return "LAND";
  }
  if (params.archetype === "echoOut") {
    if (p < params.bassSwapAt) return "ECHO OUT";
    if (p < params.handoffAt) return "ECHO→B";
    return "LAND";
  }
  if (params.archetype === "energyWash" && p < params.bassSwapAt) return "FILTER";
  if (p < params.bassSwapAt) {
    if (params.dsp.mashupMode === "acapellaDrop") return "ACAPELLA";
    return "INVITE B";
  }
  if (p < params.handoffAt) {
    return "ONE BASS";
  }
  if (p < Math.min(0.88, params.handoffAt + 0.22)) {
    if (params.archetype === "seamlessLoop") return "LONG BLEND";
    return "MASHUP";
  }
  return "LAND";
}
