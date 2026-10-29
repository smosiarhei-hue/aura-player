/** Shared AudioParam helpers for DSP nodes. */

export function setParam(
  param: AudioParam,
  value: number,
  when: number,
  immediate = false,
  rampSec = 0.04
) {
  const v = Number.isFinite(value) ? value : param.value;
  if (immediate) {
    param.cancelScheduledValues(when);
    param.setValueAtTime(v, when);
  } else {
    param.linearRampToValueAtTime(v, when + rampSec);
  }
}

export function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}
