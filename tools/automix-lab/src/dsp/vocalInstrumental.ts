/**
 * Vocal / instrumental tools — written from scratch (no ML stems).
 *
 * Stereo DJ Mid/Side:
 *   Mid  = (L + R) / 2  → vocals + kick + bass (center)
 *   Side = (L − R) / 2  → stereo instruments / FX
 *
 * Offline bake is stronger than live MidSideStemNode alone — used by the
 * auto engine when planAutomix decides A needs instrumental / B needs vocal.
 */

export type StemMode = "dry" | "instrumental" | "vocal";

/** Slice a region of an AudioBuffer (seconds). */
export function sliceBuffer(
  ctx: BaseAudioContext,
  input: AudioBuffer,
  startSec: number,
  durationSec: number
): AudioBuffer {
  const sr = input.sampleRate;
  const start = Math.max(0, Math.floor(startSec * sr));
  const len = Math.max(1, Math.min(input.length - start, Math.floor(durationSec * sr)));
  const ch = input.numberOfChannels;
  const out = ctx.createBuffer(ch, len, sr);
  for (const c of range(ch)) {
    const src = input.getChannelData(c);
    out.copyToChannel(src.subarray(start, start + len), c);
  }
  return out;
}

function range(n: number): number[] {
  return Array.from({ length: n }, (_, i) => i);
}

/** Offline render: produce a new AudioBuffer in the chosen stem mode. */
export function processBufferStem(
  ctx: BaseAudioContext,
  input: AudioBuffer,
  mode: StemMode,
  amount = 1
): AudioBuffer {
  const ch = input.numberOfChannels;
  const n = input.length;
  const sr = input.sampleRate;
  const out = ctx.createBuffer(2, n, sr);

  const L = input.getChannelData(0);
  const R = ch > 1 ? input.getChannelData(1) : input.getChannelData(0);
  const oL = out.getChannelData(0);
  const oR = out.getChannelData(1);
  const a = Math.min(1, Math.max(0, amount));

  // One-pole LF keep + presence notch state for instrumental mid-vocal cut.
  let midLp = 0;
  let midBp = 0;
  const lpAlpha = 1 - Math.exp((-2 * Math.PI * 180) / sr); // keep kick/sub in mid
  // Soft band around lead presence (~2.5 kHz) — Mid/Side alone leaves vocals here.
  const bpAlpha = 1 - Math.exp((-2 * Math.PI * 2500) / sr);

  for (let i = 0; i < n; i++) {
    const l = L[i]!;
    const r = R[i]!;
    const mid = (l + r) * 0.5;
    const side = (l - r) * 0.5;
    midLp += lpAlpha * (mid - midLp);
    midBp += bpAlpha * (mid - midLp - midBp);

    if (mode === "dry") {
      oL[i] = l;
      oR[i] = r;
    } else if (mode === "instrumental") {
      // Aggressive center-vocal cut; keep mid bass so kick/sub survive.
      const midVocal = mid - midLp;
      const midKeep =
        midLp * (1 + 0.1 * a) +
        midVocal * (1 - 0.999 * a) -
        midBp * 0.85 * a; // notch residual lead presence
      const sideBoost = side * (1 + 0.35 * a);
      oL[i] = midKeep + sideBoost;
      oR[i] = midKeep - sideBoost;
    } else {
      // Vocal focus: keep mid, shrink sides, slight presence tilt via mid emphasis.
      const sideKeep = side * (1 - 0.9 * a);
      const midBoost = mid * (1 + 0.12 * a);
      oL[i] = midBoost + sideKeep;
      oR[i] = midBoost - sideKeep;
    }
  }
  return out;
}

/**
 * Bake a mashup slice: take from cue for `durationSec`, apply stem, return buffer
 * that starts at t=0 (engine plays from 0 instead of cue).
 */
export function bakeStemSlice(
  ctx: BaseAudioContext,
  input: AudioBuffer,
  cueSec: number,
  durationSec: number,
  mode: StemMode,
  amount: number
): AudioBuffer {
  // Pad a little past blend so echo tails / rate don't cut dry.
  const slice = sliceBuffer(ctx, input, cueSec, durationSec + 1.2);
  if (mode === "dry" || amount < 0.05) return slice;
  return processBufferStem(ctx, slice, mode, amount);
}

/**
 * ONE VOCAL conflict bake for deck B:
 * instrumental through `instrUntilSec`, then crossfade into dry (lead returns for LAND).
 */
export function bakeInstrThenDry(
  ctx: BaseAudioContext,
  input: AudioBuffer,
  cueSec: number,
  durationSec: number,
  instrUntilSec: number,
  amount: number
): AudioBuffer {
  const pad = durationSec + 1.2;
  const dry = sliceBuffer(ctx, input, cueSec, pad);
  if (amount < 0.05 || instrUntilSec <= 0.05) return dry;
  const instr = processBufferStem(ctx, dry, "instrumental", amount);
  const sr = dry.sampleRate;
  const until = Math.max(1, Math.min(instr.length - 1, Math.floor(instrUntilSec * sr)));
  const fade = Math.max(1, Math.floor(0.08 * sr)); // ~80ms crossfade into dry lead
  const out = ctx.createBuffer(2, dry.length, sr);
  for (const c of [0, 1]) {
    const iCh = instr.getChannelData(c);
    const dCh = dry.getChannelData(c);
    const oCh = out.getChannelData(c);
    for (let i = 0; i < out.length; i++) {
      if (i < until - fade) {
        oCh[i] = iCh[i]!;
      } else if (i < until) {
        const t = (i - (until - fade)) / fade;
        oCh[i] = iCh[i]! * (1 - t) + dCh[i]! * t;
      } else {
        oCh[i] = dCh[i]!;
      }
    }
  }
  return out;
}

/**
 * Realtime Mid/Side splitter graph (live automation on top of baked stems).
 */
export class MidSideStemNode {
  readonly input: GainNode;
  readonly output: GainNode;
  private midGain: GainNode;
  private sideGain: GainNode;
  private presence: BiquadFilterNode;

  constructor(ctx: AudioContext) {
    this.input = ctx.createGain();
    this.output = ctx.createGain();

    const split = ctx.createChannelSplitter(2);
    const merge = ctx.createChannelMerger(2);

    const lToMid = ctx.createGain();
    const rToMid = ctx.createGain();
    const lToSide = ctx.createGain();
    const rToSide = ctx.createGain();
    lToMid.gain.value = 0.5;
    rToMid.gain.value = 0.5;
    lToSide.gain.value = 0.5;
    rToSide.gain.value = -0.5;

    this.midGain = ctx.createGain();
    this.sideGain = ctx.createGain();
    this.midGain.gain.value = 1;
    this.sideGain.gain.value = 1;

    this.presence = ctx.createBiquadFilter();
    this.presence.type = "peaking";
    this.presence.frequency.value = 2800;
    this.presence.Q.value = 0.9;
    this.presence.gain.value = 0;

    // Bass keep on mid when instrumentalizing (live)
    const midBass = ctx.createBiquadFilter();
    midBass.type = "lowshelf";
    midBass.frequency.value = 160;
    midBass.gain.value = 0;

    this.input.connect(split);
    split.connect(lToMid, 0);
    split.connect(rToMid, 1);
    split.connect(lToSide, 0);
    split.connect(rToSide, 1);

    const midSum = ctx.createGain();
    const sideSum = ctx.createGain();
    lToMid.connect(midSum);
    rToMid.connect(midSum);
    lToSide.connect(sideSum);
    rToSide.connect(sideSum);

    midSum.connect(this.midGain);
    this.midGain.connect(midBass);
    midBass.connect(this.presence);

    const midToL = ctx.createGain();
    const midToR = ctx.createGain();
    const sideToL = ctx.createGain();
    const sideToR = ctx.createGain();
    midToL.gain.value = 1;
    midToR.gain.value = 1;
    sideToL.gain.value = 1;
    sideToR.gain.value = -1;

    this.presence.connect(midToL);
    this.presence.connect(midToR);
    sideSum.connect(this.sideGain);
    this.sideGain.connect(sideToL);
    this.sideGain.connect(sideToR);

    midToL.connect(merge, 0, 0);
    sideToL.connect(merge, 0, 0);
    midToR.connect(merge, 0, 1);
    sideToR.connect(merge, 0, 1);
    merge.connect(this.output);

    (this as unknown as { _midBass: BiquadFilterNode })._midBass = midBass;
  }

  setInstrumental(amount: number, when: number, immediate = false) {
    const a = Math.min(1, Math.max(0, amount));
    // Harder mid cut — 0.88 still leaked lead vocals under dual-deck.
    const mid = 1 - 0.97 * a;
    const side = 1 + 0.28 * a;
    this.setGain(this.midGain.gain, mid, when, immediate);
    this.setGain(this.sideGain.gain, side, when, immediate);
    this.setGain(this.presence.gain, -9 * a, when, immediate);
    const midBass = (this as unknown as { _midBass: BiquadFilterNode })._midBass;
    this.setGain(midBass.gain, 4.5 * a, when, immediate); // restore kick/sub
  }

  setVocal(amount: number, when: number, immediate = false) {
    const a = Math.min(1, Math.max(0, amount));
    const mid = 1 + 0.12 * a;
    const side = 1 - 0.88 * a;
    this.setGain(this.midGain.gain, mid, when, immediate);
    this.setGain(this.sideGain.gain, side, when, immediate);
    this.setGain(this.presence.gain, 5 * a, when, immediate);
    const midBass = (this as unknown as { _midBass: BiquadFilterNode })._midBass;
    this.setGain(midBass.gain, 0, when, immediate);
  }

  setDry(when: number, immediate = false) {
    this.setGain(this.midGain.gain, 1, when, immediate);
    this.setGain(this.sideGain.gain, 1, when, immediate);
    this.setGain(this.presence.gain, 0, when, immediate);
    const midBass = (this as unknown as { _midBass: BiquadFilterNode })._midBass;
    this.setGain(midBass.gain, 0, when, immediate);
  }

  private setGain(param: AudioParam, value: number, when: number, immediate: boolean) {
    if (immediate) {
      param.cancelScheduledValues(when);
      param.setValueAtTime(value, when);
    } else {
      param.linearRampToValueAtTime(value, when + 0.04);
    }
  }

  disconnect() {
    try {
      this.input.disconnect();
      this.output.disconnect();
    } catch {
      /* ignore */
    }
  }
}
