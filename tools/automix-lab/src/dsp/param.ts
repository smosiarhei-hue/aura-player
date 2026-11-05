/** Shared AudioParam helpers for DSP nodes. */

const scheduled = new WeakMap<AudioParam, number>();

/**
 * Glide an AudioParam toward `value`.
 * Calling this every animation frame used to cancel the ramp and restart it,
 * so levels lagged and clicked. Identical targets are ignored; a new target
 * uses one setTargetAtTime and is left alone until it actually moves.
 */
export function setParam(
  param: AudioParam,
  value: number,
  when: number,
  immediate = false,
  rampSec = 0.12
) {
  const v = Number.isFinite(value) ? value : param.value;
  const prev = scheduled.get(param);
  const eps = Math.max(1e-4, Math.abs(v) * 0.004);
  if (!immediate && prev !== undefined && Math.abs(prev - v) < eps) return;
  scheduled.set(param, v);
  if (immediate) {
    param.cancelScheduledValues(when);
    param.setValueAtTime(v, when);
    return;
  }
  const tc = Math.max(0.05, rampSec * 0.55);
  try {
    param.setTargetAtTime(v, when, tc);
  } catch {
    param.setValueAtTime(v, when);
  }
}

export function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}
