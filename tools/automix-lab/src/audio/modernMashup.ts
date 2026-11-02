/**
 * Modern mashup craft — how the Automix window should *sound*.
 *
 * Hard product rule:
 *   Dual mashup (A bed × B vocal) ONLY when A outro is already instrumental.
 *   If A still sings at the mix-out → Safe Exit — still a long AutoMix phrase
 *   (LOCK / bass / echo LAND), never a 1s blink and never two full leads.
 *
 * Modes:
 *   acapellaDrop  — A outro already a bed → B vocal invites early
 *   safeExit      — A still sings → phrase-length Automix, one lead
 *   textureBed    — A still sings × B instrumental bed (no B vocalize)
 *   instrumentalWash — both beds → filter/texture drama
 */

export type ModernMashupMode =
  | "acapellaDrop"
  | "safeExit"
  | "textureBed"
  | "instrumentalWash";

export type ModernMashupCraft = {
  mode: ModernMashupMode;
  /** Human label for UI. */
  label: string;
  /** Progress where A must be fully instrumentalized. */
  aInstrReadyAt: number;
  /** Progress where B leaves instrumental gate and lead may open. */
  bVocalOpenAt: number;
  /** Keep A audible as texture through mashup peak (dual layer). */
  dualLayerPeak: number;
  /** Offline bake A as instrumental. */
  bakeInstrA: boolean;
  /** Offline bake B instrumental → dry/vocal through open. */
  bakeInstrB: boolean;
  /** Offline bake B as vocal-forward (only when A is already a bed). */
  bakeVocalB: boolean;
  /** Sidechain-duck A mids under B groove (0…1). */
  sidechainA: number;
  story: string;
};

/**
 * Pick the modern mashup grammar from measured vocal presence at cues.
 * Dual-layer B vocal is allowed ONLY when A outro is already a bed.
 */
export function chooseModernMashup(
  vocalOut: number,
  vocalIn: number,
  bassSwapAt: number,
  handoffAt: number
): ModernMashupCraft {
  // Strict: "instrumental outro" — not Mid/Side hope.
  const aIsInstrOutro = vocalOut < 0.35;
  const bHasVocal = vocalIn >= 0.4;
  const bass = Math.min(0.55, Math.max(0.14, bassSwapAt));
  const handoff = Math.min(0.78, Math.max(bass + 0.12, handoffAt));

  // Ideal: A outro already a bed × B full mix.
  // B's lead opens just after A is a bed — still inside the invite, not at LAND.
  if (aIsInstrOutro && bHasVocal) {
    return {
      mode: "acapellaDrop",
      label: "Acapella Drop",
      aInstrReadyAt: 0.08,
      bVocalOpenAt: 0.12,
      dualLayerPeak: 0.86,
      bakeInstrA: vocalOut >= 0.18, // residual center vocal → carve, clean beds stay dry
      bakeInstrB: false,
      bakeVocalB: false,
      sidechainA: 0,
      story: "A instrumental bed × B vocal → ONE BASS → MASHUP → LAND",
    };
  }

  // A still sings → NO dual mashup. Still a full Automix phrase (not Crossfade).
  if (!aIsInstrOutro && bHasVocal) {
    return {
      mode: "safeExit",
      label: "Safe Exit",
      aInstrReadyAt: 0.48,
      bVocalOpenAt: 0.58,
      dualLayerPeak: 0.22,
      bakeInstrA: false,
      bakeInstrB: false,
      bakeVocalB: false,
      sidechainA: 0,
      story: "A outro still sings → LOCK · ONE BASS · Echo Exit · LAND",
    };
  }

  if (!aIsInstrOutro && !bHasVocal) {
    return {
      mode: "textureBed",
      label: "Texture Bed",
      aInstrReadyAt: 0.28,
      bVocalOpenAt: 0.55,
      // 0.7 left A short while incoming lag kept B quiet — a hole at prog≈0.
      // Stay near the lead; the bed fills under it instead of arriving late.
      dualLayerPeak: 0.88,
      bakeInstrA: vocalOut >= 0.5,
      bakeInstrB: false,
      bakeVocalB: false,
      sidechainA: 0,
      story: "A carve × B instrumental bed → LAND",
    };
  }

  void handoff;
  return {
    mode: "instrumentalWash",
    label: "Instrumental Wash",
    aInstrReadyAt: 0.2,
    bVocalOpenAt: 0.3,
    dualLayerPeak: 0.8,
    bakeInstrA: false,
    bakeInstrB: false,
    bakeVocalB: false,
    sidechainA: 0,
    story: "Dual instrumental texture → LAND",
  };
}
