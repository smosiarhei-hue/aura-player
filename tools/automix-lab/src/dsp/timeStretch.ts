/**
 * Pitch-preserving tempo change (Apple AutoMix-style beatmatch).
 *
 * `playbackRate` on an AudioBufferSourceNode resamples: tempo and pitch move
 * together. `detune` does not undo that. The spec compounds them:
 *
 *   computedPlaybackRate = playbackRate * 2^(detune/1200)
 *
 * so `detuneCents = -1200*log2(rate)` while `playbackRate = rate` cancels the
 * tempo change and leaves the audio at the original speed. That is not key-lock.
 *
 * Beatmatch therefore offline-stretches the blend with overlap-add (WSOLA-lite)
 * and the engine plays the result at playbackRate 1. Camelot `pitchCentsB`
 * stays on `detune` by itself — a separate, intentional key nudge.
 *
 * `rate` uses playbackRate semantics: 1.06 is 6% faster and a shorter buffer.
 */

import { sliceBuffer } from "./vocalInstrumental";

export type BeatmatchTransport = {
  rateA: number;
  rateB: number;
  detuneA: number;
  detuneB: number;
};

/** Cents that would cancel the pitch of a resampling `playbackRate`. */
export function tempoPitchCompensationCents(rate: number): number {
  if (!(rate > 0) || Math.abs(rate - 1) < 1e-8) return 0;
  return -1200 * Math.log2(rate);
}

/** True when the tempo ratio would audibly move pitch if only resampled (~7¢). */
export function tempoNeedsPitchLock(rate: number): boolean {
  return Number.isFinite(rate) && Math.abs(rate - 1) >= 0.004;
}

/**
 * Transport for one envelope frame.
 * Locked decks were already time-stretched, so their source rate stays 1.
 * Unlocked decks keep `playbackRate` and do not also get inverse detune —
 * that pair would null the tempo. Camelot cents are always detune-only.
 */
export function beatmatchTransport(
  rates: { outgoing: number; incoming: number },
  camelotCents: number,
  lockedA: boolean,
  lockedB: boolean
): BeatmatchTransport {
  return {
    rateA: lockedA ? 1 : rates.outgoing,
    rateB: lockedB ? 1 : rates.incoming,
    detuneA: 0,
    detuneB: camelotCents,
  };
}

function clampRate(rate: number): number {
  if (!(rate > 0)) return 1;
  return Math.min(2, Math.max(0.5, rate));
}

function grainSize(sampleRate: number): { win: number; hs: number; search: number } {
  let win = Math.round(sampleRate * 0.04);
  if (win % 2) win += 1;
  win = Math.max(256, win);
  return {
    win,
    hs: win >> 1,
    search: Math.max(8, Math.round(sampleRate * 0.008)),
  };
}

function allocBuffer(
  ctx: BaseAudioContext | undefined,
  channels: number,
  length: number,
  sampleRate: number
): AudioBuffer {
  const n = Math.max(1, length | 0);
  const ch = Math.max(1, channels | 0);
  if (ctx) return ctx.createBuffer(ch, n, sampleRate);
  const Ctor = globalThis.OfflineAudioContext;
  if (!Ctor) throw new Error("timeStretchBuffer needs an AudioContext");
  const offline = new Ctor(ch, n, sampleRate);
  return offline.createBuffer(ch, n, sampleRate);
}

function buildWindows(win: number, hs: number): { mid: Float32Array; head: Float32Array } {
  const mid = new Float32Array(win);
  const head = new Float32Array(win);
  for (let i = 0; i < win; i++) {
    // Periodic Hann. 50% overlap sums to 1.
    mid[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / win));
    // First grain stays full-scale so the mashup does not fade in.
    head[i] = i < hs ? 1 : mid[i]!;
  }
  return { mid, head };
}

function seekBest(
  mono: Float32Array,
  prev: number,
  ideal: number,
  hs: number,
  search: number,
  maxStart: number
): number {
  const fallback = Math.max(0, Math.min(maxStart, Math.round(ideal)));
  const a0 = prev + hs;
  const ov = hs;
  if (a0 < 0 || a0 + ov > mono.length) return fallback;
  const step = 4;
  let na = 0;
  for (let i = 0; i < ov; i += step) {
    const v = mono[a0 + i] ?? 0;
    na += v * v;
  }
  if (na < 1e-8) return fallback;

  const lo = Math.max(0, Math.round(ideal - search));
  const hi = Math.min(maxStart, Math.round(ideal + search));
  if (hi < lo) return fallback;
  let best = fallback;
  let bestScore = -Infinity;
  const invSearch = 1 / Math.max(1, search);
  for (let cand = lo; cand <= hi; cand += step) {
    const b0 = cand;
    if (b0 + ov > mono.length) break;
    let dot = 0;
    let nb = 0;
    for (let i = 0; i < ov; i += step) {
      const vb = mono[b0 + i] ?? 0;
      dot += (mono[a0 + i] ?? 0) * vb;
      nb += vb * vb;
    }
    const sim = dot / Math.sqrt(na * nb + 1e-18);
    const score = sim - Math.abs(cand - ideal) * invSearch * 0.02;
    if (score > bestScore) {
      bestScore = score;
      best = cand;
    }
  }
  return best;
}

/**
 * Offline WSOLA-lite stretch.
 * `rate` 1.06 → 6% faster, shorter buffer, original pitch.
 * A function of output progress (0…1) bakes a tempo envelope (lock → LAND).
 * `outDurationSec` is required for a variable rate; otherwise duration/rate.
 */
export function timeStretchBuffer(
  buffer: AudioBuffer,
  rate: number | ((outputProgress: number) => number),
  outDurationSec?: number,
  ctx?: BaseAudioContext
): AudioBuffer {
  const sampleRate = buffer.sampleRate;
  const channels = buffer.numberOfChannels;
  if (!(sampleRate > 0) || buffer.length < 8 || channels < 1) return buffer;

  const numeric = typeof rate === "number";
  const rateAt: (p: number) => number = numeric
    ? () => clampRate(rate)
    : (p) => clampRate(rate(p));
  const outSec =
    outDurationSec != null && outDurationSec > 0
      ? outDurationSec
      : buffer.duration / (numeric ? clampRate(rate) : 1);
  const outLen = Math.max(1, Math.round(outSec * sampleRate));
  const { win, hs, search } = grainSize(sampleRate);

  if (buffer.length < win * 2) {
    return resampleLinear(buffer, outLen, ctx);
  }

  const inputs: Float32Array[] = [];
  for (let c = 0; c < channels; c++) inputs.push(buffer.getChannelData(c));
  const inLen = buffer.length;
  const mono = new Float32Array(inLen);
  if (channels === 1) mono.set(inputs[0]!);
  else {
    const a = inputs[0]!;
    const b = inputs[1]!;
    for (let i = 0; i < inLen; i++) mono[i] = ((a[i] ?? 0) + (b[i] ?? 0)) * 0.5;
  }

  const outputs: Float32Array[] = [];
  for (let c = 0; c < channels; c++) outputs.push(new Float32Array(outLen));
  const weight = new Float32Array(outLen);
  const { mid, head } = buildWindows(win, hs);
  const maxStart = Math.max(0, inLen - win);

  let ideal = 0;
  let prev = 0;
  const frames = Math.ceil(outLen / hs) + 1;
  for (let frame = 0; frame < frames; frame++) {
    const outPos = frame * hs;
    if (outPos >= outLen) break;
    let chosen = 0;
    if (frame === 0) {
      chosen = 0;
      ideal = 0;
    } else {
      const progress = Math.min(1, outPos / Math.max(1, outLen - 1));
      ideal += hs * rateAt(progress);
      if (ideal >= inLen) break;
      chosen =
        ideal > maxStart ? maxStart : seekBest(mono, prev, ideal, hs, search, maxStart);
    }
    const w = frame === 0 ? head : mid;
    const srcPos = Math.max(0, Math.min(maxStart, chosen));
    for (let c = 0; c < channels; c++) {
      const src = inputs[c]!;
      const dst = outputs[c]!;
      for (let i = 0; i < win; i++) {
        const o = outPos + i;
        if (o >= outLen) break;
        const s = src[srcPos + i];
        if (s == null) break;
        const g = w[i]!;
        dst[o] += s * g;
        if (c === 0) weight[o] += g;
      }
    }
    prev = srcPos;
    if (frame > 0 && ideal > maxStart) break;
  }

  for (let c = 0; c < channels; c++) {
    const dst = outputs[c]!;
    for (let i = 0; i < outLen; i++) {
      const g = weight[i] ?? 0;
      if (g > 0.55) dst[i] = (dst[i] ?? 0) / g;
    }
  }

  const out = allocBuffer(ctx, channels, outLen, sampleRate);
  for (let c = 0; c < channels; c++) {
    out.getChannelData(c).set(outputs[c]!);
  }
  return out;
}

/** Linear fallback for clips shorter than one analysis grain. Not pitch-locked. */
function resampleLinear(
  buffer: AudioBuffer,
  outLen: number,
  ctx: BaseAudioContext | undefined
): AudioBuffer {
  const out = allocBuffer(ctx, buffer.numberOfChannels, outLen, buffer.sampleRate);
  const ratio = buffer.length / Math.max(1, outLen);
  for (let c = 0; c < buffer.numberOfChannels; c++) {
    const src = buffer.getChannelData(c);
    const dst = out.getChannelData(c);
    const last = src.length - 1;
    for (let i = 0; i < outLen; i++) {
      const x = i * ratio;
      const i0 = Math.max(0, Math.min(last, Math.floor(x)));
      const i1 = Math.min(last, i0 + 1);
      const f = x - i0;
      dst[i] = (src[i0] ?? 0) * (1 - f) + (src[i1] ?? 0) * f;
    }
  }
  return out;
}

function sourceSpanSeconds(
  outSec: number,
  sampleRate: number,
  rateAt: (outputProgress: number) => number
): number {
  const { win, hs, search } = grainSize(sampleRate);
  const outLen = Math.max(1, Math.round(outSec * sampleRate));
  let ideal = 0;
  let maxEnd = win + search;
  const frames = Math.ceil(outLen / hs) + 1;
  for (let frame = 0; frame < frames; frame++) {
    const outPos = frame * hs;
    if (outPos >= outLen) break;
    if (frame > 0) {
      const progress = Math.min(1, outPos / Math.max(1, outLen - 1));
      ideal += hs * clampRate(rateAt(progress));
    }
    const end = ideal + win + search;
    if (end > maxEnd) maxEnd = end;
  }
  return maxEnd / sampleRate;
}

/**
 * Stretch the slice that starts at `startSec` into `outDurationSec` of
 * output. `rateAt` is playback speed versus output progress (0…1).
 */
export function stretchPlaybackWindow(
  ctx: BaseAudioContext,
  buffer: AudioBuffer,
  startSec: number,
  outDurationSec: number,
  rateAt: (outputProgress: number) => number
): AudioBuffer {
  const span = sourceSpanSeconds(outDurationSec, buffer.sampleRate, rateAt) + 0.06;
  const avail = Math.max(0.05, buffer.duration - Math.max(0, startSec));
  const slice = sliceBuffer(ctx, buffer, Math.max(0, startSec), Math.min(span, avail));
  return timeStretchBuffer(slice, rateAt, outDurationSec, ctx);
}
