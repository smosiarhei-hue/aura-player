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
 */

export {
  MidSideStemNode,
  processBufferStem,
  bakeStemSlice,
  bakeInstrThenDry,
  sliceBuffer,
  type StemMode,
} from "./vocalInstrumental";
export { BassEqNode } from "./bassEq";
export { FilterSweepNode } from "./filters";
export { EchoOutNode } from "./echo";
export { stemFxAt, type StemFxAt } from "./stemEnvelopes";
export { setParam, clamp } from "./param";
