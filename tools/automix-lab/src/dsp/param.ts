/** Shared AudioParam helpers for DSP nodes. */

/**
 * Smooth AudioParam updates without stacking unbounded linearRamp queues
 * (that caused stepped / overshooting automation every RAF tick).
 */
export function setParam(
  param: AudioParam,
  value: number,
  when: number,
  immediate = false,
  rampSec = 0.08
) {
  const v = Number.isFinite(value) ? value : param.value;
  if (immediate) {
    param.cancelScheduledValues(when);
    param.setValueAtTime(v, when);
    return;
  }
  const hold =
    typeof (param as AudioParam & { cancelAndHoldAtTime?: (t: number) => void })
      .cancelAndHoldAtTime === "function"
      ? () =>
          (param as AudioParam & { cancelAndHoldAtTime: (t: number) => void }).cancelAndHoldAtTime(
            when
          )
      : () => {
          param.cancelScheduledValues(when);
          param.setValueAtTime(param.value, when);
        };
  hold();
  const dur = Math.max(0.04, rampSec);
  param.linearRampToValueAtTime(v, when + dur);
}

export function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}
