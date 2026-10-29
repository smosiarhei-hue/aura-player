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
  /** Modern mashup mode label (acapellaDrop / vocalSwap / …). */
  mashupMode: string;
  /** Sidechain duck of A under B groove (0…1), applied offline on bake. */
  sidechainA: number;
};

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
  blendDurationSec: 16,
  cueASec: 0,
  cueBSec: 0,
  archetype: "dropSwap",
  dsp: defaultDsp(),
});

export function smoothstep(t: number): number {
  const x = Math.min(1, Math.max(0, t));
  return x * x * (3 - 2 * x);
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

/** Dual-layer mashup volumes — shaped by TZ transition type. */
export function volumesAt(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const hold = Math.min(0.72, Math.max(0.12, params.outgoingVolumeHold));
  const lag = Math.min(0.28, Math.max(0.01, params.incomingVolumeLag));
  const handoff = Math.min(0.85, Math.max(hold, params.handoffAt));

  // Cut on the 1 — almost no dual-layer; snap at handoff.
  if (params.archetype === "cutOnOne") {
    const cut = Math.max(0.35, Math.min(0.7, handoff));
    if (p < cut - 0.04) {
      return { outgoing: 1, incoming: p < lag ? smoothstep(p / Math.max(lag, 0.001)) * 0.15 : 0.2 };
    }
    if (p < cut + 0.04) {
      const t = smoothstep((p - (cut - 0.04)) / 0.08);
      return { outgoing: 1 - t, incoming: 0.2 + 0.8 * t };
    }
    return { outgoing: 0, incoming: 1 };
  }

  // Echo Out — A holds into delay while B locks under (dual layer), then LAND.
  if (params.archetype === "echoOut") {
    let out: number;
    if (p <= hold) out = 1 - (p / Math.max(hold, 0.001)) * 0.18;
    else if (p <= handoff) {
      const t = smoothstep((p - hold) / Math.max(0.001, handoff - hold));
      out = Math.max(0.28, 0.82 * (1 - t * 0.55));
    } else {
      out = Math.max(0, 0.28 * (1 - smoothstep((p - handoff) / Math.max(0.001, 1 - handoff))));
    }
    let inn: number;
    if (p <= lag) inn = 0.68 * smoothstep(p / Math.max(lag, 0.001));
    else if (p <= handoff) {
      const t = smoothstep((p - lag) / Math.max(0.001, handoff - lag));
      inn = 0.68 + 0.28 * t;
    } else {
      inn = Math.min(1, 0.96 + 0.04 * smoothstep((p - handoff) / Math.max(0.001, 1 - handoff)));
    }
    return { outgoing: out, incoming: inn };
  }

  // Modern mashup / EQ Blend — both layers stay loud on the remix bar.
  const modern =
    params.dsp.mashupMode === "vocalSwap" || params.dsp.mashupMode === "acapellaDrop";
  const mashupFloor =
    params.archetype === "smartCrossfade" ? 0.58 : modern ? 0.78 : 0.72;
  const mashupPeak =
    params.archetype === "smartCrossfade" ? 0.92 : modern ? 0.98 : 0.96;
  const dualFloor =
    params.archetype === "smartCrossfade" ? 0.28 : modern ? 0.48 : 0.38;
  // Hold ends exactly at the mid-segment start level (no 0.90→0.92 step).
  const holdEnd = params.archetype === "smartCrossfade" ? 0.75 : 0.92;
  // Mid segment lands exactly on dualFloor at handoff (no step into LAND).
  const midDrop = Math.max(0.05, 1 - dualFloor / Math.max(0.001, holdEnd));

  let out: number;
  if (p <= hold) {
    out = 1.0 - (p / Math.max(hold, 0.001)) * (1 - holdEnd);
  } else if (p <= handoff) {
    const t = smoothstep((p - hold) / Math.max(0.001, handoff - hold));
    // Keep A texture present through mashup peak (instrumental bed under B vocal).
    out = Math.max(dualFloor, holdEnd * (1 - t * midDrop));
  } else {
    const t = smoothstep((p - handoff) / Math.max(0.001, 1 - handoff));
    out = Math.max(0, dualFloor * (1 - t));
  }

  let inn: number;
  if (p <= lag) {
    // Gentler invite (smoothstep²) — B rises as a guest, not a slam to mashupFloor.
    const t = smoothstep(p / Math.max(lag, 0.001));
    inn = mashupFloor * smoothstep(t);
  } else if (p <= handoff) {
    const t = smoothstep((p - lag) / Math.max(0.001, handoff - lag));
    inn = mashupFloor + (mashupPeak - mashupFloor) * t;
  } else {
    const t = smoothstep((p - handoff) / Math.max(0.001, 1 - handoff));
    inn = Math.min(1, mashupPeak + (1 - mashupPeak) * t);
  }
  return { outgoing: out, incoming: inn };
}

export function bassGainDbAt(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const bassAt = Math.min(0.7, Math.max(0.12, params.bassSwapAt));
  // Cap depth so ONE BASS doesn't dig a −20 dB hole that the limiter then "muffles".
  const depth = Math.min(1.15, Math.max(0.5, params.bassDepth));
  const killA = smoothstep(p / Math.max(0.001, bassAt * 0.9));
  const restoreB = smoothstep(
    (p - bassAt * 0.28) / Math.max(0.001, bassAt + 0.18 - bassAt * 0.28)
  );
  return {
    outgoing: -12 * depth * killA,
    incoming: -12 * depth * (1 - Math.min(1, Math.max(0, restoreB))),
  };
}

export function playbackRatesAt(
  p: number,
  params: MashupParams
): { outgoing: number; incoming: number } {
  const lockAt = Math.min(0.28, Math.max(0.1, params.bassSwapAt * 0.72));
  const settleAt = Math.max(
    params.handoffAt + 0.08,
    Math.min(0.88, Math.max(0.62, params.handoffAt + 0.2))
  );
  if (p < lockAt) {
    const t = smoothstep(p / Math.max(0.001, lockAt));
    return {
      outgoing: 1 + (params.rateA - 1) * t,
      incoming: 1 + (params.rateB - 1) * t,
    };
  }
  if (p < settleAt) {
    return { outgoing: params.rateA, incoming: params.rateB };
  }
  const t = smoothstep((p - settleAt) / Math.max(0.001, 1 - settleAt));
  return {
    outgoing: params.rateA + (1 - params.rateA) * t,
    incoming: params.rateB + (1 - params.rateB) * t,
  };
}

export function pitchCentsAt(p: number, params: MashupParams): number {
  if (Math.abs(params.pitchCentsB) < 0.5) return 0;
  const rampIn = Math.min(0.22, Math.max(0.08, params.bassSwapAt * 0.72));
  const holdEnd = Math.max(rampIn + 0.05, params.handoffAt);
  if (p < rampIn) return params.pitchCentsB * smoothstep(p / Math.max(0.001, rampIn));
  if (p <= holdEnd) return params.pitchCentsB;
  const t = smoothstep((p - holdEnd) / Math.max(0.001, 1 - holdEnd));
  return params.pitchCentsB * (1 - t);
}

export function phaseLabel(p: number, params: MashupParams): string {
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
  if (params.archetype === "cutOnOne") {
    if (p < params.handoffAt - 0.05) return "PHRASE";
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
    if (params.dsp.vocalBAt <= p && params.dsp.mashupMode === "vocalSwap") return "VOCAL SWAP";
    return "ONE BASS";
  }
  if (p < Math.min(0.88, params.handoffAt + 0.22)) {
    if (params.archetype === "seamlessLoop") return "LONG BLEND";
    if (params.dsp.mashupMode === "vocalSwap" || params.dsp.mashupMode === "acapellaDrop") {
      return "MASHUP";
    }
    return "MASHUP";
  }
  return "LAND";
}
