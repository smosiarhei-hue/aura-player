/**
 * Modern mashup craft — how the Automix window should *sound*.
 *
 * Not a radio crossfade. A short remix bar:
 *   A instrumental bed × B vocal + groove, one bass, phrase-locked.
 *
 * Modes (chosen from vocal presence at cues):
 *   acapellaDrop  — A outro already instrumental → B vocal invites early
 *   vocalSwap     — both still sing → carve A fast, B groove then B lead on mashup peak
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
 * Thresholds match planAutomix / ONE VOCAL intent.
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

  // Ideal Apple-style mashup: instrumental outro × incoming lead.
  if (!aHasVocal && bHasVocal) {
    return {
      mode: "acapellaDrop",
      label: "Acapella Drop",
      aInstrReadyAt: 0.08,
      bVocalOpenAt: 0.06,
      dualLayerPeak: 0.92,
      bakeInstrA: vocalOut >= 0.28, // light carve if residual mid-vocal
      bakeInstrB: false,
      bakeVocalB: true,
      sidechainA: 0.55,
      story: "A bed × B vocal early → ONE BASS → MASHUP → LAND",
    };
  }

  // Both still sing — the case that used to kill the mashup by holding B mute until LAND.
  // Modern: carve A ASAP, B groove under, open B lead once A is a bed (mashup peak).
  if (aHasVocal && bHasVocal) {
    const aReady = Math.min(0.18, Math.max(0.08, bass * 0.55));
    const bOpen = Math.min(handoff - 0.06, Math.max(aReady + 0.1, bass + 0.04));
    return {
      mode: "vocalSwap",
      label: "Vocal Swap Mashup",
      aInstrReadyAt: aReady,
      bVocalOpenAt: bOpen,
      dualLayerPeak: 0.95,
      bakeInstrA: true,
      bakeInstrB: true,
      bakeVocalB: false,
      sidechainA: 0.7,
      story: "Carve A → B groove → B vocal on mashup peak × A instr → LAND",
    };
  }

  if (aHasVocal && !bHasVocal) {
    return {
      mode: "textureBed",
      label: "Texture Bed",
      aInstrReadyAt: 0.4,
      bVocalOpenAt: 0.55,
      dualLayerPeak: 0.7,
      bakeInstrA: vocalOut >= 0.55,
      bakeInstrB: false,
      bakeVocalB: false,
      sidechainA: 0.25,
      story: "A lead soft-carve × B instrumental bed → LAND",
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
    sidechainA: 0.35,
    story: "Dual instrumental texture → filters → LAND",
  };
}
