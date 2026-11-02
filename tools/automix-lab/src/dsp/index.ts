/**
 * Automix Lab DSP toolkit — all written from scratch (Web Audio, no ML stems).
 *
 * Tools:
 *   MidSideStemNode     — vocal remove / instrumental remove (karaoke Mid/Side)
 *   processBufferStem   — offline stem render of an AudioBuffer
 *   BassEqNode          — bass kill/on + mid vocal duck + air
 *   FilterSweepNode     — HPF riser / LPF reveal
 *   EchoOutNode         — tempo-synced echo-out
 *   stemFxAt            — envelopes that drive stems+FX through DJ acts
 *   timeStretchBuffer   — offline WSOLA-lite tempo change, original pitch
 */

export {
  MidSideStemNode,
  processBufferStem,
  bakeStemSlice,
  bakeInstrThenDry,
  applySidechainDuck,
  sliceBuffer,
  type StemMode,
  type InstrCarve,
} from "./vocalInstrumental";
export { BassEqNode } from "./bassEq";
export { FilterSweepNode } from "./filters";
export { EchoOutNode } from "./echo";
export { stemFxAt, type StemFxAt } from "./stemEnvelopes";
export { setParam, clamp } from "./param";
export {
  timeStretchBuffer,
  stretchPlaybackWindow,
  beatmatchTransport,
  tempoNeedsPitchLock,
  tempoPitchCompensationCents,
  type BeatmatchTransport,
} from "./timeStretch";
