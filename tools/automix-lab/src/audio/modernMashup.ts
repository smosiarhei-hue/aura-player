/**
 * Modern mashup craft — how the Automix window should *sound*.
 *
 * Canonical handoff the user wants:
 *   A → instrumental bed (lead gone)
 *   B → vocal on the grid (BPM / bar / Camelot)
 *   Never two leads stacked.
 *
 * Modes:
 *   acapellaDrop  — A outro already a bed → B vocal invites early
 *   vocalSwap     — both still sing → carve A first, only then open B lead
 *   textureBed    — A still sings × B instrumental bed (no B vocalize)
 *   instrumentalWash — both beds → filter/texture drama
 */

export type ModernMashupMode =
  | "acapellaDrop"
  | "vocalSwap"
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
 * Hard rule when B has a lead: A becomes the bed BEFORE B vocal opens.
 */
export function chooseModernMashup(
  vocalOut: number,
  vocalIn: number,
  bassSwapAt: number,
  handoffAt: number
): ModernMashupCraft {
  const aHasVocal = vocalOut >= 0.42;
  const bHasVocal = vocalIn >= 0.4;
  const bass = Math.min(0.55, Math.max(0.14, bassSwapAt));
  const handoff = Math.min(0.78, Math.max(bass + 0.12, handoffAt));

  // Ideal: A outro already a bed × B full mix.
  if (!aHasVocal && bHasVocal) {
    return {
      mode: "acapellaDrop",
      label: "Acapella Drop",
      aInstrReadyAt: 0.06,
      bVocalOpenAt: 0.08,
      dualLayerPeak: 0.92,
      bakeInstrA: vocalOut >= 0.28, // residual lead still in A → carve it
      bakeInstrB: false,
      bakeVocalB: false,
      sidechainA: 0,
      story: "A instrumental bed × B vocal → ONE BASS → MASHUP → LAND",
    };
  }

  // Both still sing: A must finish instrumentalize before B lead opens.
  if (aHasVocal && bHasVocal) {
    const aReady = Math.min(0.14, Math.max(0.06, bass * 0.4));
    // At least ~22% of the blend (~1–2 bars) of A-as-bed under B groove, then B vocal.
    const bOpen = Math.min(
      Math.max(aReady + 0.22, bass + 0.14, 0.34),
      Math.max(aReady + 0.22, handoff - 0.06)
    );
    return {
      mode: "vocalSwap",
      label: "Vocal Relay",
      aInstrReadyAt: aReady,
      bVocalOpenAt: bOpen,
      dualLayerPeak: 0.9,
      bakeInstrA: true,
      bakeInstrB: true,
      bakeVocalB: false,
      sidechainA: 0,
      story: "A → instrumental · then B vocal on grid (BPM/bar/key) · no dual lead",
    };
  }

  if (aHasVocal && !bHasVocal) {
    return {
      mode: "textureBed",
      label: "Texture Bed",
      aInstrReadyAt: 0.28,
      bVocalOpenAt: 0.55,
      dualLayerPeak: 0.7,
      bakeInstrA: vocalOut >= 0.5,
      bakeInstrB: false,
      bakeVocalB: false,
      sidechainA: 0,
      story: "A carve × B instrumental bed → LAND",
    };
  }

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
