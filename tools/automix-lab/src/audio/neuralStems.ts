/**
 * HTDemucs window → the buffers AutoMix actually plays.
 * The ending song stays as the instrumental bed. The next song enters
 * as vocal, then opens into its dry mix at LAND.
 * Mid/Side is not applied on top of these buffers.
 */

export function mixLandChannel(
  dry: Float32Array,
  stem: Float32Array,
  landFrame: number,
  fadeFrames: number
): Float32Array {
  const n = Math.min(dry.length, stem.length);
  const out = new Float32Array(n);
  const fade = Math.max(1, fadeFrames);
  const until = landFrame;
  const bloom = until > 0 && until < n;
  const fadeStart = bloom && until > fade ? until - fade : 0;
  for (let i = 0; i < n; i++) {
    if (!bloom) {
      out[i] = stem[i] ?? 0;
      continue;
    }
    if (i >= until) {
      out[i] = dry[i] ?? 0;
    } else if (i >= fadeStart) {
      const t = (i - fadeStart) / fade;
      const s = t * t * (3 - 2 * t);
      const wa = Math.cos(s * Math.PI * 0.5);
      const wb = Math.sin(s * Math.PI * 0.5);
      out[i] = (stem[i] ?? 0) * wa + (dry[i] ?? 0) * wb;
    } else {
      out[i] = stem[i] ?? 0;
    }
  }
  return out;
}

export function sliceToBuffer(
  ctx: BaseAudioContext,
  src: AudioBuffer,
  startSec: number,
  frames: number,
  rate: number
): AudioBuffer {
  const out = ctx.createBuffer(2, Math.max(1, frames), rate);
  for (let ch = 0; ch < 2; ch++) {
    const srcCh = src.getChannelData(Math.min(ch, src.numberOfChannels - 1));
    const dst = out.getChannelData(ch);
    const srcRate = src.sampleRate;
    for (let i = 0; i < dst.length; i++) {
      const pos = (startSec + i / rate) * srcRate;
      const i0 = Math.floor(pos);
      const i1 = i0 + 1;
      const t = pos - i0;
      const a = i0 >= 0 && i0 < srcCh.length ? srcCh[i0]! : 0;
      const b = i1 >= 0 && i1 < srcCh.length ? srcCh[i1]! : 0;
      dst[i] = a * (1 - t) + b * t;
    }
  }
  return out;
}

/**
 * Repeat `loopSec` from `startSec`.
 * Seams crossfade. When `holdSec` is set, the loop lets go there and
 * fades across `releaseSec` instead of playing under the next song.
 */
export function crossfadedLoop(
  ctx: BaseAudioContext,
  src: AudioBuffer,
  startSec: number,
  loopSec: number,
  holdSec = 0,
  releaseSec = 0
): AudioBuffer {
  const rate = src.sampleRate;
  const start = Math.max(0, Math.floor(startSec * rate));
  const loopFrames = Math.max(1, Math.floor(loopSec * rate));
  const total = Math.max(loopFrames, src.length - start);
  const out = ctx.createBuffer(2, total, rate);
  const fade = Math.min(Math.floor(rate * 0.03), Math.floor(loopFrames * 0.22));
  const hold = holdSec > 0 ? Math.floor(holdSec * rate) : 0;
  const release = Math.max(1, Math.floor((releaseSec > 0 ? releaseSec : 0.8) * rate));
  for (let ch = 0; ch < 2; ch++) {
    const srcCh = src.getChannelData(Math.min(ch, src.numberOfChannels - 1));
    const dst = out.getChannelData(ch);
    const read = (frame: number) => {
      const i = start + frame;
      return i >= 0 && i < srcCh.length ? srcCh[i]! : 0;
    };
    for (let i = 0; i < total; i++) {
      const pos = i % loopFrames;
      let sample = read(pos);
      if (fade > 1 && i >= fade && pos < fade) {
        const t = pos / fade;
        const s = t * t * (3 - 2 * t);
        const tail = read(loopFrames - fade + pos);
        const wa = Math.cos(s * Math.PI * 0.5);
        const wb = Math.sin(s * Math.PI * 0.5);
        sample = tail * wa + sample * wb;
      }
      if (hold > 0 && i >= hold) {
        const past = i - hold;
        if (past >= release) sample = 0;
        else {
          const t = past / release;
          const s = t * t * (3 - 2 * t);
          sample *= Math.cos(s * Math.PI * 0.5);
        }
      }
      dst[i] = sample;
    }
  }
  return out;
}

export function bloomInstrumental(
  ctx: BaseAudioContext,
  instrumental: AudioBuffer,
  dryWindow: AudioBuffer,
  landAtSec: number,
  fadeSec = 1.1
): AudioBuffer {
  const rate = instrumental.sampleRate;
  const frames = instrumental.length;
  const out = ctx.createBuffer(2, frames, rate);
  const landFrame = Math.round(landAtSec * rate);
  const fadeFrames = Math.max(1, Math.round(Math.max(0.4, fadeSec) * rate));
  for (let ch = 0; ch < 2; ch++) {
    const mixed = mixLandChannel(
      dryWindow.getChannelData(Math.min(ch, dryWindow.numberOfChannels - 1)),
      instrumental.getChannelData(Math.min(ch, instrumental.numberOfChannels - 1)),
      landFrame,
      fadeFrames
    );
    out.getChannelData(ch).set(mixed);
  }
  return out;
}
