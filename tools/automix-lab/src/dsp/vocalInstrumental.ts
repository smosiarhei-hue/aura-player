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

import { setParam } from "./param";

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

/**
 * Offline Mid/Side stem render — stronger than live graph alone.
 * Instrumental: keep sub/kick + wide sides, notch center lead + presence.
 * Vocal: shrink sides, lift mid presence (modern acapella-ish layer).
 */
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

  // Multiband mid: sub keep + body + presence notch (modern karaoke carve).
  let midLp = 0; // ~150 Hz — kick/sub
  let midBody = 0; // ~800 Hz — body
  let midPres = 0; // ~2.8 kHz — lead presence
  const lpA = 1 - Math.exp((-2 * Math.PI * 150) / sr);
  const bodyA = 1 - Math.exp((-2 * Math.PI * 800) / sr);
  const presA = 1 - Math.exp((-2 * Math.PI * 2800) / sr);

  for (let i = 0; i < n; i++) {
    const l = L[i]!;
    const r = R[i]!;
    const mid = (l + r) * 0.5;
    const side = (l - r) * 0.5;
    midLp += lpA * (mid - midLp);
    const midHi = mid - midLp;
    midBody += bodyA * (midHi - midBody);
    midPres += presA * (midHi - midBody - midPres);

    if (mode === "dry") {
      oL[i] = l;
      oR[i] = r;
    } else if (mode === "instrumental") {
      // Notch lead presence only — keep body/air so the bed stays bright, not muffled.
      const midKeep =
        midLp * (1 + 0.08 * a) +
        midBody * (1 - 0.22 * a) +
        midPres * (1 - 0.92 * a);
      const sideBoost = side * (1 + 0.22 * a);
      oL[i] = midKeep + sideBoost;
      oR[i] = midKeep - sideBoost;
    } else {
      // Light vocal focus — don't collapse the stereo image / air.
      const sideKeep = side * (1 - 0.45 * a);
      const midBoost = midLp + midBody * (1 + 0.05 * a) + midPres * (1 + 0.2 * a);
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
 * Bake B for modern mashup:
 * instrumental groove through `instrUntilSec`, then crossfade into dry lead
 * (vocal returns for the mashup peak / LAND — not a hard mute until the end).
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
  // Equal-power bloom (~350ms) so the lead opens without a hard gate click.
  const fade = Math.max(1, Math.floor(0.35 * sr));
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
        const ease = t * t * (3 - 2 * t);
        const a = Math.cos(ease * Math.PI * 0.5);
        const b = Math.sin(ease * Math.PI * 0.5);
        oCh[i] = iCh[i]! * a + dCh[i]! * b;
      } else {
        oCh[i] = dCh[i]!;
      }
    }
  }
  return out;
}

/**
 * Duck A under B's groove (offline sidechain feel) so the mashup bed breathes.
 * Only the mashup window buffers — peak RAM stays on the slice, not full tracks.
 */
export function applySidechainDuck(
  bed: AudioBuffer,
  key: AudioBuffer,
  amount: number
): AudioBuffer {
  const a = Math.min(1, Math.max(0, amount));
  if (a < 0.05) return bed;
  const n = Math.min(bed.length, key.length);
  const sr = bed.sampleRate;
  const dest = new AudioBuffer({
    length: bed.length,
    numberOfChannels: 2,
    sampleRate: sr,
  });
  const kL = key.getChannelData(0);
  const kR = key.numberOfChannels > 1 ? key.getChannelData(1) : kL;
  const bL = bed.getChannelData(0);
  const bR = bed.numberOfChannels > 1 ? bed.getChannelData(1) : bL;
  const oL = dest.getChannelData(0);
  const oR = dest.getChannelData(1);

  let env = 0;
  const attack = 1 - Math.exp((-2 * Math.PI * 40) / sr);
  const release = 1 - Math.exp((-2 * Math.PI * 8) / sr);
  const depth = 0.55 * a; // max ~−5.5 dB-ish linear duck on bed

  for (let i = 0; i < n; i++) {
    const keyMono = Math.abs((kL[i]! + kR[i]!) * 0.5);
    if (keyMono > env) env += attack * (keyMono - env);
    else env += release * (keyMono - env);
    const duck = 1 - Math.min(depth, env * depth * 3.2);
    oL[i] = bL[i]! * duck;
    oR[i] = bR[i]! * duck;
  }
  for (let i = n; i < bed.length; i++) {
    oL[i] = bL[i]!;
    oR[i] = bR[i]!;
  }
  return dest;
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
    // Presence notch + light mid tuck — keep body/air (no dull karaoke blanket).
    const mid = 1 - 0.55 * a;
    const side = 1 + 0.18 * a;
    this.setGain(this.midGain.gain, mid, when, immediate);
    this.setGain(this.sideGain.gain, side, when, immediate);
    this.setGain(this.presence.gain, -7 * a, when, immediate);
    const midBass = (this as unknown as { _midBass: BiquadFilterNode })._midBass;
    this.setGain(midBass.gain, 2.5 * a, when, immediate);
  }

  setVocal(amount: number, when: number, immediate = false) {
    const a = Math.min(1, Math.max(0, amount));
    // Mild focus only — never collapse sides/air.
    const mid = 1 + 0.06 * a;
    const side = 1 - 0.35 * a;
    this.setGain(this.midGain.gain, mid, when, immediate);
    this.setGain(this.sideGain.gain, side, when, immediate);
    this.setGain(this.presence.gain, 2.5 * a, when, immediate);
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
    // Shared cancelAndHold + ramp — avoids RAF ramp stacking / clicks.
    setParam(param, value, when, immediate, 0.09);
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
