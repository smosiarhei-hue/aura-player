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

/** How hard to carve the center lead when instrumentalizing. */
export type InstrCarve = "bed" | "leadKill";

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
    // getChannelData().set — Node web-audio-api copyToChannel rejects some views,
    // and `new AudioBuffer` is not on the global in that runtime.
    writeChannel(out, c, src.subarray(start, start + len));
  }
  return out;
}

function writeChannel(buf: AudioBuffer, channel: number, src: ArrayLike<number>, offset = 0) {
  const dst = buf.getChannelData(channel);
  const n = Math.min(src.length, Math.max(0, dst.length - offset));
  if (n <= 0) return;
  if (src instanceof Float32Array) {
    dst.set(src.subarray(0, n), offset);
    return;
  }
  for (let i = 0; i < n; i++) dst[offset + i] = src[i] ?? 0;
}

function range(n: number): number[] {
  return Array.from({ length: n }, (_, i) => i);
}

type Biquad = { b0: number; b1: number; b2: number; a1: number; a2: number };
type BiquadState = { x1: number; x2: number; y1: number; y2: number };

/** RBJ lowpass. Coefficients are normalized (a0 = 1). */
function designLowpass(freq: number, q: number, sr: number): Biquad {
  const w0 = (2 * Math.PI * freq) / sr;
  const cosw = Math.cos(w0);
  const alpha = Math.sin(w0) / (2 * q);
  const b0 = (1 - cosw) / 2;
  const b1 = 1 - cosw;
  const b2 = (1 - cosw) / 2;
  const a0 = 1 + alpha;
  return {
    b0: b0 / a0,
    b1: b1 / a0,
    b2: b2 / a0,
    a1: (-2 * cosw) / a0,
    a2: (1 - alpha) / a0,
  };
}

function biquadStep(f: Biquad, s: BiquadState, x: number): number {
  const y = f.b0 * x + f.b1 * s.x1 + f.b2 * s.x2 - f.a1 * s.y1 - f.a2 * s.y2;
  s.x2 = s.x1;
  s.x1 = x;
  s.y2 = s.y1;
  s.y1 = y;
  return y;
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
  amount = 1,
  carve: InstrCarve = "bed"
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
  const kill = carve === "leadKill";

  // Multiband mid: sub keep + body + mid-vocal + presence.
  let midLp = 0; // ~150 Hz — kick/sub
  let midBody = 0; // ~800 Hz — body
  let midLead = 0; // ~1.6 kHz — vocal formant
  let midPres = 0; // ~2.8 kHz — lead presence
  const lpA = 1 - Math.exp((-2 * Math.PI * 150) / sr);
  const bodyA = 1 - Math.exp((-2 * Math.PI * 800) / sr);
  const leadA = 1 - Math.exp((-2 * Math.PI * 1600) / sr);
  const presA = 1 - Math.exp((-2 * Math.PI * 2800) / sr);

  // bed = soft karaoke tuck. Partial cuts leak a 1.6 kHz lead across bands, so
  // leadKill does not use them: center keeps a Butterworth sub and sides stay
  // full-band. Muting the whole signal above 150 Hz is the phone filter.
  const bodyCut = 0.22;
  const formantCut = 0.55;
  const presCut = 0.92;
  const sideBoostAmt = 0.22;
  const midLpKeep = 1.08;
  let midMud = 0;
  const mudA = 1 - Math.exp((-2 * Math.PI * 350) / sr);
  const mudCut = 0.15;
  // 4th-order Butterworth @ 72 Hz. Knee stays under vocal fundamentals
  // (~120 Hz) while kick/sub around 40–60 Hz still pass.
  const lpLo = designLowpass(72, 0.5411961, sr);
  const lpHi = designLowpass(72, 1.306563, sr);
  const subLo = { x1: 0, x2: 0, y1: 0, y2: 0 };
  const subHi = { x1: 0, x2: 0, y1: 0, y2: 0 };
  // 8 ms dry→wet edges so the bake doesn't click against the unprocessed track.
  const edge = Math.min(n >> 2, Math.max(1, Math.floor(sr * 0.008)));
  const edgeW = (i: number) => {
    const t =
      i < edge ? i / edge : i > n - 1 - edge ? (n - 1 - i) / edge : 1;
    const x = Math.min(1, Math.max(0, t));
    return x * x * (3 - 2 * x);
  };

  // Prime one-poles with the first sample so the filter doesn't thump in.
  {
    const mid0 = ((L[0] ?? 0) + (R[0] ?? 0)) * 0.5;
    midLp = mid0;
    // DC steady state — a zero state thumps when the slice starts on a kick.
    subLo.x1 = subLo.x2 = subLo.y1 = subLo.y2 = mid0;
    subHi.x1 = subHi.x2 = subHi.y1 = subHi.y2 = mid0;
  }

  for (let i = 0; i < n; i++) {
    const l = L[i]!;
    const r = R[i]!;
    const mid = (l + r) * 0.5;
    const side = (l - r) * 0.5;
    midLp += lpA * (mid - midLp);
    const midHi = mid - midLp;
    midMud += mudA * (midHi - midMud);
    const midAboveMud = midHi - midMud;
    midBody += bodyA * (midAboveMud - midBody);
    const midRest = midAboveMud - midBody;
    midLead += leadA * (midRest - midLead);
    midPres += presA * (midRest - midLead - midPres);

    let wetL = l;
    let wetR = r;
    if (mode === "dry") {
      wetL = l;
      wetR = r;
    } else if (mode === "instrumental" && kill) {
      const sub = biquadStep(lpHi, subHi, biquadStep(lpLo, subLo, mid));
      // Amount ≥ ~0.94 is a full center mute (planner bakes 0.94–1).
      const depth = Math.min(1, a * 1.06);
      const midKeep = sub * (1 + 0.04 * depth);
      const sideKeep = side * (1 + 0.2 * depth);
      const fullL = midKeep + sideKeep;
      const fullR = midKeep - sideKeep;
      wetL = l + (fullL - l) * depth;
      wetR = r + (fullR - r) * depth;
    } else if (mode === "instrumental") {
      const midKeep =
        midLp * (1 + (midLpKeep - 1) * a) +
        midMud * (1 - mudCut * a) +
        midBody * (1 - bodyCut * a) +
        midLead * (1 - formantCut * a) +
        midPres * (1 - presCut * a);
      const sideBoost = side * (1 + sideBoostAmt * a);
      wetL = midKeep + sideBoost;
      wetR = midKeep - sideBoost;
    } else {
      // Light vocal focus — don't collapse the stereo image / air.
      const sideKeep = side * (1 - 0.45 * a);
      const midBoost =
        midLp +
        midMud * (1 + 0.02 * a) +
        midBody * (1 + 0.05 * a) +
        midLead * (1 + 0.12 * a) +
        midPres * (1 + 0.2 * a);
      wetL = midBoost + sideKeep;
      wetR = midBoost - sideKeep;
    }
    const w = mode === "dry" ? 1 : edgeW(i);
    oL[i] = l + (wetL - l) * w;
    oR[i] = r + (wetR - r) * w;
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
  amount: number,
  carve: InstrCarve = "bed"
): AudioBuffer {
  // Pad a little past blend so echo tails / rate don't cut dry.
  const slice = sliceBuffer(ctx, input, cueSec, durationSec + 1.2);
  if (mode === "dry" || amount < 0.05) return slice;
  return processBufferStem(ctx, slice, mode, amount, carve);
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
  amount: number,
  carve: InstrCarve = "bed"
): AudioBuffer {
  const pad = durationSec + 1.2;
  const dry = sliceBuffer(ctx, input, cueSec, pad);
  if (amount < 0.05 || instrUntilSec <= 0.05) return dry;
  const instr = processBufferStem(ctx, dry, "instrumental", amount, carve);
  const sr = dry.sampleRate;
  const until = Math.max(1, Math.min(instr.length - 1, Math.floor(instrUntilSec * sr)));
  // Equal-power bloom (~350ms). Cap it so a short gate still has a killed hold —
  // otherwise the ramp starts in the dry vocal and the dual-lead window never clears.
  const fade = Math.max(1, Math.min(Math.floor(0.35 * sr), Math.floor(until * 0.45)));
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
  amount: number,
  ctx?: BaseAudioContext
): AudioBuffer {
  const a = Math.min(1, Math.max(0, amount));
  if (a < 0.05) return bed;
  const n = Math.min(bed.length, key.length);
  const sr = bed.sampleRate;
  // Prefer createBuffer — `new AudioBuffer(...)` is missing under node web-audio-api.
  const dest =
    ctx?.createBuffer(2, bed.length, sr) ??
    (typeof AudioBuffer !== "undefined"
      ? new AudioBuffer({
          length: bed.length,
          numberOfChannels: 2,
          sampleRate: sr,
        })
      : (() => {
          throw new Error("applySidechainDuck needs AudioContext in Node");
        })());
  const kL = key.getChannelData(0);
  const kR = key.numberOfChannels > 1 ? key.getChannelData(1) : kL;
  const bL = bed.getChannelData(0);
  const bR = bed.numberOfChannels > 1 ? bed.getChannelData(1) : bL;
  const oL = dest.getChannelData(0);
  const oR = dest.getChannelData(1);

  // Low-band duck only. Full-band sample followers pump the whole bed on
  // every syllable (~6 dB) and read as a level jump, not ONE BASS.
  let env = 0;
  let keyLp = 0;
  let bedLpL = 0;
  let bedLpR = 0;
  const lpA = 1 - Math.exp((-2 * Math.PI * 140) / sr);
  const attack = 1 - Math.exp(-1 / (0.01 * sr));
  const release = 1 - Math.exp(-1 / (0.16 * sr));
  const maxDuckDb = 5.2 * a;

  for (let i = 0; i < n; i++) {
    const keyMono = (kL[i]! + kR[i]!) * 0.5;
    keyLp += lpA * (keyMono - keyLp);
    const keyLow = Math.abs(keyLp);
    if (keyLow > env) env += attack * (keyLow - env);
    else env += release * (keyLow - env);
    const duck = 10 ** ((-maxDuckDb * Math.min(1, env * 3.5)) / 20);
    bedLpL += lpA * (bL[i]! - bedLpL);
    bedLpR += lpA * (bR[i]! - bedLpR);
    const hiL = bL[i]! - bedLpL;
    const hiR = bR[i]! - bedLpR;
    oL[i] = bedLpL * duck + hiL;
    oR[i] = bedLpR * duck + hiR;
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
  private mud: BiquadFilterNode;
  private formant: BiquadFilterNode;
  private presence: BiquadFilterNode;
  private midBass: BiquadFilterNode;

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

    // Low-mid mud (~450 Hz) — vocal fundamentals leak above the kick shelf.
    this.mud = ctx.createBiquadFilter();
    this.mud.type = "peaking";
    this.mud.frequency.value = 450;
    this.mud.Q.value = 0.7;
    this.mud.gain.value = 0;

    // Formant pocket (~1.6 kHz) — critical for Vocal Relay leadKill.
    this.formant = ctx.createBiquadFilter();
    this.formant.type = "peaking";
    this.formant.frequency.value = 1600;
    this.formant.Q.value = 1.15;
    this.formant.gain.value = 0;

    this.presence = ctx.createBiquadFilter();
    this.presence.type = "peaking";
    this.presence.frequency.value = 2800;
    this.presence.Q.value = 0.95;
    this.presence.gain.value = 0;

    // Bass keep on mid when instrumentalizing (live)
    this.midBass = ctx.createBiquadFilter();
    this.midBass.type = "lowshelf";
    this.midBass.frequency.value = 160;
    this.midBass.gain.value = 0;

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
    this.midGain.connect(this.midBass);
    this.midBass.connect(this.mud);
    this.mud.connect(this.formant);
    this.formant.connect(this.presence);

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
  }

  setInstrumental(amount: number, when: number, immediate = false, leadKill = false) {
    const a = Math.min(1, Math.max(0, amount));
    // bed: light demuffle · leadKill: nuclear mid mute (center ≈ kick only).
    const mid = 1 - (leadKill ? 0.97 : 0.55) * a;
    const side = 1 + (leadKill ? 0.55 : 0.18) * a;
    this.setGain(this.midGain.gain, mid, when, immediate);
    this.setGain(this.sideGain.gain, side, when, immediate);
    this.setGain(this.mud.gain, (leadKill ? -22 : -3) * a, when, immediate);
    this.setGain(this.formant.gain, (leadKill ? -28 : -4) * a, when, immediate);
    this.setGain(this.presence.gain, (leadKill ? -28 : -7) * a, when, immediate);
    this.setGain(this.midBass.gain, (leadKill ? 5 : 2.5) * a, when, immediate);
  }

  setVocal(amount: number, when: number, immediate = false) {
    const a = Math.min(1, Math.max(0, amount));
    // Mild focus only — never collapse sides/air.
    const mid = 1 + 0.06 * a;
    const side = 1 - 0.35 * a;
    this.setGain(this.midGain.gain, mid, when, immediate);
    this.setGain(this.sideGain.gain, side, when, immediate);
    this.setGain(this.mud.gain, 0, when, immediate);
    this.setGain(this.formant.gain, 1.5 * a, when, immediate);
    this.setGain(this.presence.gain, 2.5 * a, when, immediate);
    this.setGain(this.midBass.gain, 0, when, immediate);
  }

  setDry(when: number, immediate = false) {
    this.setGain(this.midGain.gain, 1, when, immediate);
    this.setGain(this.sideGain.gain, 1, when, immediate);
    this.setGain(this.mud.gain, 0, when, immediate);
    this.setGain(this.formant.gain, 0, when, immediate);
    this.setGain(this.presence.gain, 0, when, immediate);
    this.setGain(this.midBass.gain, 0, when, immediate);
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
