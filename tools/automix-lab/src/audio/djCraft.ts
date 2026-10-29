/**
 * DJ craft for a “wow” Automix transition (Apple / club mashup grammar).
 *
 * A beautiful transition is a short story with ONE hero bass and ONE clear vocal
 * focus at a time — not a volume crossfade.
 *
 * ACT 1 · LOCK (0…~15%)
 *   Kicks already share a grid. Listener feels the pulse unite before the blend
 *   is obvious. Never start mid-bar.
 *
 * ACT 2 · INVITE (~15…bassSwap)
 *   Bring B in as a guest: drums/body under A. If A outro is already instrumental,
 *   B vocal can enter earlier (true mashup). If A is still singing, keep B’s vocal
 *   softer until the pocket opens — never two lead vocals fighting.
 *
 * ACT 3 · ONE BASS (bassSwap → handoff)
 *   Kill A’s low end on a downbeat; B’s kick/bass owns the floor. This is the
 *   “oh shit” moment — muddy double-bass is what makes amateur mixes ugly.
 *
 * ACT 4 · MASHUP PEAK (around handoff)
 *   Both decks audible on purpose: A texture/hook + B groove/vocal. Peak energy
 *   should feel like a remix bar, then commit to B.
 *
 * ACT 5 · LAND (handoff → 1)
 *   A exits cleanly (HPF / fade). B is already “home”. Settle rate/pitch to
 *   natural tempo so the next song feels native, not pitched forever.
 *
 * Cue picking (what DJs scan for by ear):
 *   A mixOut → outro / breakdown / instrumental tail after the song has played
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
  handoffAt: number
): DjAct {
  const lockEnd = Math.min(0.18, bassSwapAt * 0.65);
  if (p < lockEnd) return "LOCK";
  if (p < bassSwapAt) return "INVITE";
  if (p < handoffAt) return "ONE_BASS";
  if (p < Math.min(0.88, handoffAt + 0.22)) return "MASHUP_PEAK";
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
