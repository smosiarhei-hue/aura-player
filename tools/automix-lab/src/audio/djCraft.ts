/**
 * DJ craft for a modern Automix mashup (Apple / club / radio-edit grammar).
 *
 * A beautiful transition is a short remix story — not a volume crossfade.
 * One hero bass. One lead vocal at a time. Both layers audible on purpose
 * during the mashup peak (A instrumental bed × B vocal + groove).
 *
 * ACT 1 · LOCK (0…~15%)
 *   Kicks already share a grid. Listener feels the pulse unite before the blend
 *   is obvious. Never start mid-bar.
 *
 * ACT 2 · INVITE (~15…bassSwap)
 *   Bring B in as a guest: drums/body under A.
 *   Acapella Drop: B vocal can enter early over A instrumental outro.
 *   Vocal Swap: B stays instrumental groove while A lead is carved away.
 *
 * ACT 3 · ONE BASS (bassSwap → mashup)
 *   Kill A’s low end on a downbeat; B’s kick/bass owns the floor.
 *
 * ACT 4 · MASHUP PEAK (vocal open → handoff)
 *   The modern moment: A instrumental texture × B lead vocal + groove.
 *   Feels like a remix bar — not two dry leads, not a quiet fade.
 *
 * ACT 5 · LAND (handoff → 1)
 *   A exits cleanly (HPF / fade). B is already home. Settle rate/pitch.
 *
 * Cue picking (what DJs scan for by ear):
 *   A mixOut → outro / breakdown / instrumental tail
 *   B mixIn  → past dead air, into groove or 8–16 bars before an early drop
 *   Window   → 8 or 16 bars (phrase), never a random number of seconds
 */

export type DjAct =
  | "LOCK"
  | "INVITE"
  | "ONE_BASS"
  | "MASHUP_PEAK"
  | "LAND";

export function djActAt(
  p: number,
  bassSwapAt: number,
  handoffAt: number,
  vocalOpenAt = 0
): DjAct {
  const lockEnd = Math.min(0.18, bassSwapAt * 0.65);
  const mashupStart =
    vocalOpenAt > 0.05
      ? Math.min(handoffAt - 0.02, Math.max(bassSwapAt, vocalOpenAt))
      : Math.min(handoffAt, bassSwapAt + 0.08);
  if (p < lockEnd) return "LOCK";
  if (p < bassSwapAt) return "INVITE";
  if (p < mashupStart) return "ONE_BASS";
  if (p < Math.min(0.9, handoffAt + 0.18)) return "MASHUP_PEAK";
  return "LAND";
}

export function djActLabel(act: DjAct, bpm: number): string {
  switch (act) {
    case "LOCK":
      return bpm > 30 ? `LOCK ${Math.round(bpm)}` : "LOCK";
    case "INVITE":
      return "INVITE B";
    case "ONE_BASS":
      return "ONE BASS";
    case "MASHUP_PEAK":
      return "MASHUP";
    case "LAND":
      return "LAND";
  }
}
