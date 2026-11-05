/**
 * HTDemucs window → the buffers AutoMix actually plays.
 * A is the vocal stem. B is instrumental until LAND, then the dry mix.
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

export function bloomInstrumental(
  ctx: BaseAudioContext,
  instrumental: AudioBuffer,
  dryWindow: AudioBuffer,
  landAtSec: number
): AudioBuffer {
  const rate = instrumental.sampleRate;
  const frames = instrumental.length;
  const out = ctx.createBuffer(2, frames, rate);
  const landFrame = Math.round(landAtSec * rate);
  const fadeFrames = Math.max(1, Math.round(0.08 * rate));
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
