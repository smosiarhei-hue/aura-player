/** Offline per-track analysis (Apple Automix–style cues + BPM + Camelot). */

import { computeChroma, estimateCamelotKey } from "./keyCamelot";

export type TrackAIProfile = {
  name: string;
  durationSec: number;
  bpm: number;
  bpmConfidence: number;
  /** Camelot wheel key e.g. "8A", "12B". */
  camelotKey: string | null;
  keyConfidence: number;
  energy: number[]; // ~1 sample / 0.25s, 0…1
  vocalPresence: number[]; // mid-band proxy per energy hop
  mixInSec: number;
  mixOutSec: number;
  hasFadeOut: boolean;
  endsInSilence: boolean;
  tempoStability: number;
  /**
   * Kick/downbeat phase in seconds from t=0, modulo one beat.
   * Crude grid for cue slip — not a transcribed bar number.
   */
  downbeatSec?: number;
  /** 0…1. planAutomix slips cues only when both tracks are high. */
  downbeatConfidence?: number;
  reason: string;
};

const HOP_SEC = 0.25;

function monoFromBuffer(buffer: AudioBuffer): Float32Array {
  const ch = buffer.numberOfChannels;
  const n = buffer.length;
  const out = new Float32Array(n);
  for (let c = 0; c < ch; c++) {
    const data = buffer.getChannelData(c);
    for (let i = 0; i < n; i++) out[i] += data[i] / ch;
  }
  return out;
}

/** Downsample for analysis (~22050). */
function downsample(samples: Float32Array, fromRate: number, toRate: number): Float32Array {
  if (toRate >= fromRate) return samples;
  const ratio = fromRate / toRate;
  const n = Math.floor(samples.length / ratio);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const src = Math.floor(i * ratio);
    out[i] = samples[src] ?? 0;
  }
  return out;
}

function energyCurve(samples: Float32Array, sampleRate: number): number[] {
  const hop = Math.max(1, Math.floor(sampleRate * HOP_SEC));
  const curve: number[] = [];
  for (let i = 0; i + hop <= samples.length; i += hop) {
    let sum = 0;
    for (let j = 0; j < hop; j++) {
      const v = samples[i + j]!;
      sum += v * v;
    }
    curve.push(Math.sqrt(sum / hop));
  }
  const peak = Math.max(...curve, 1e-9);
  return curve.map((v) => Math.min(1, v / peak));
}

/** Mid-band energy proxy via difference of low-passed vs full (vocal-ish). */
function vocalCurve(samples: Float32Array, sampleRate: number, energy: number[]): number[] {
  // One-pole HPF ~300Hz then energy — approximates presence band.
  const rc = 1 / (2 * Math.PI * 300);
  const dt = 1 / sampleRate;
  const alpha = rc / (rc + dt);
  let prevX = 0;
  let prevY = 0;
  const hop = Math.max(1, Math.floor(sampleRate * HOP_SEC));
  const out: number[] = [];
  for (let i = 0; i + hop <= samples.length; i += hop) {
    let sum = 0;
    for (let j = 0; j < hop; j++) {
      const x = samples[i + j]!;
      const y = alpha * (prevY + x - prevX);
      prevX = x;
      prevY = y;
      sum += y * y;
    }
    out.push(Math.sqrt(sum / hop));
  }
  const peak = Math.max(...out, 1e-9);
  const norm = out.map((v) => Math.min(1, v / peak));
  // Blend with energy length
  const n = Math.min(norm.length, energy.length);
  return Array.from({ length: n }, (_, i) => norm[i]! * 0.65 + energy[i]! * 0.35);
}

function onsetEnvelope(energy: number[]): number[] {
  const out: number[] = [0];
  for (let i = 1; i < energy.length; i++) {
    out.push(Math.max(0, energy[i]! - energy[i - 1]!));
  }
  return out;
}

/** Fine hop for tempo — 0.25s energy hops cannot separate 118 vs 124 BPM. */
const BPM_HOP_SEC = 0.01;

/**
 * BPM via autocorrelation of a fine onset envelope (10 ms hops).
 * Old 250 ms hops mapped ~110–130 BPM onto the same lag (= always “120”).
 */
export function estimateBPMFromSamples(
  samples: Float32Array,
  sampleRate: number
): { bpm: number; confidence: number } {
  const hop = Math.max(1, Math.floor(sampleRate * BPM_HOP_SEC));
  const env: number[] = [];
  for (let i = 0; i + hop <= samples.length; i += hop) {
    let sum = 0;
    for (let j = 0; j < hop; j++) {
      const v = samples[i + j]!;
      sum += v * v;
    }
    env.push(Math.sqrt(sum / hop));
  }
  const onset = onsetEnvelope(env);
  // Use middle 60% of the track (skip intro silence / outro fade).
  const i0 = Math.floor(onset.length * 0.15);
  const i1 = Math.floor(onset.length * 0.85);
  const region = onset.slice(i0, Math.max(i0 + 64, i1));
  if (region.length < 64) return { bpm: 120, confidence: 0.1 };

  const minBpm = 70;
  const maxBpm = 180;
  const candidates: { bpm: number; score: number }[] = [];

  for (let bpm = minBpm; bpm <= maxBpm; bpm++) {
    const lag = Math.round(60 / bpm / BPM_HOP_SEC);
    if (lag < 2 || lag >= region.length >> 1) continue;
    let corr = 0;
    let norm = 0;
    for (let i = 0; i + lag < region.length; i++) {
      corr += region[i]! * region[i + lag]!;
      norm += region[i]! * region[i]!;
    }
    const score = norm > 1e-9 ? corr / norm : 0;
    // Mild preference for club/pop pocket 95–135 without forcing 120.
    const center = 115;
    const bias = 1 - Math.min(1, Math.abs(bpm - center) / 90) * 0.12;
    candidates.push({ bpm, score: score * bias });
  }

  candidates.sort((a, b) => b.score - a.score);
  if (!candidates.length) return { bpm: 120, confidence: 0.1 };

  // Pick best in 90–140 if close to global best; else global.
  let best = candidates[0]!;
  for (const c of candidates.slice(0, 12)) {
    if (c.bpm >= 90 && c.bpm <= 140 && c.score >= best.score * 0.92) {
      best = c;
      break;
    }
  }

  // Resolve half/double vs neighbours (e.g. 62 vs 124).
  let bpm = best.bpm;
  const scoreAt = (b: number) =>
    candidates.find((c) => c.bpm === b)?.score ?? 0;
  if (bpm < 90 && scoreAt(bpm * 2) >= best.score * 0.85) bpm *= 2;
  if (bpm > 150 && scoreAt(Math.round(bpm / 2)) >= best.score * 0.85) bpm = Math.round(bpm / 2);

  const mean =
    candidates.reduce((s, c) => s + c.score, 0) / Math.max(1, candidates.length);
  const confidence = Math.min(1, Math.max(0.2, (best.score - mean) * 5 + 0.25));
  return { bpm: Math.round(bpm * 10) / 10, confidence };
}

/** @deprecated coarse energy path — kept for callers; prefer estimateBPMFromSamples. */
export function estimateBPM(energy: number[], hopSec = HOP_SEC): { bpm: number; confidence: number } {
  const onset = onsetEnvelope(energy);
  if (onset.length < 32) return { bpm: 120, confidence: 0.1 };
  const minBpm = 70;
  const maxBpm = 180;
  const minLag = Math.max(2, Math.round(60 / maxBpm / hopSec));
  const maxLag = Math.min(onset.length >> 1, Math.round(60 / minBpm / hopSec));
  let bestLag = minLag;
  let bestScore = -1;
  for (let lag = minLag; lag <= maxLag; lag++) {
    let corr = 0;
    let norm = 0;
    for (let i = 0; i + lag < onset.length; i++) {
      corr += onset[i]! * onset[i + lag]!;
      norm += onset[i]! * onset[i]!;
    }
    const score = norm > 1e-9 ? corr / norm : 0;
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }
  let bpm = 60 / (bestLag * hopSec);
  while (bpm < 80) bpm *= 2;
  while (bpm > 160) bpm /= 2;
  return { bpm: Math.round(bpm * 10) / 10, confidence: 0.35 };
}

function meanSlice(values: number[], from: number, to: number): number {
  const a = Math.max(0, Math.floor(from));
  const b = Math.min(values.length, Math.ceil(to));
  if (b <= a) return 0;
  let s = 0;
  for (let i = a; i < b; i++) s += values[i]!;
  return s / (b - a);
}

/**
 * Mix-out: where a DJ would start the blend — must leave a real phrase of audio
 * after the cue (16–32s), not the last 1–2 seconds of the file.
 */
function detectMixOut(energy: number[], vocal: number[], duration: number): { mixOut: number; fade: boolean; silent: boolean } {
  const n = energy.length;
  // Always leave room for an 8–16 bar mashup window.
  const minTailSec = duration > 150 ? 32 : duration > 100 ? 24 : 16;
  const fallback = Math.max(0, duration - minTailSec);
  if (n < 8) return { mixOut: fallback, fade: false, silent: false };

  const silent = meanSlice(energy, n * 0.92, n) < 0.08;
  const fade = meanSlice(energy, n * 0.7, n * 0.85) > meanSlice(energy, n * 0.9, n) * 1.35;

  const bodyMean = meanSlice(energy, n * 0.2, n * 0.6);
  const vocalBody = meanSlice(vocal, n * 0.2, n * 0.6);

  // Search last 35% for vocal drop / soft outro, but never past (duration - minTail).
  const searchStart = Math.floor(n * 0.65);
  const searchEnd = Math.max(searchStart + 4, Math.floor((duration - minTailSec) / HOP_SEC));

  let bestIdx = Math.floor(fallback / HOP_SEC);
  let bestScore = -1;
  for (let i = searchStart; i < Math.min(n - 4, searchEnd); i++) {
    const localE = meanSlice(energy, i, i + 6);
    const localV = meanSlice(vocal, i, i + 6);
    const nextV = meanSlice(vocal, i + 4, Math.min(n, i + 12));
    // Prefer: vocals dropping while bed still has energy (classic instrumental outro).
    const vocalDrop = vocalBody > 0.2 && localV < vocalBody * 0.6 && nextV <= localV * 1.1;
    const softOutro = localE < bodyMean * 0.8;
    const score =
      (vocalDrop ? 2.5 : 0) +
      (softOutro ? 1 : 0) +
      (1 - localV) * 0.8 +
      Math.min(1, localE) * 0.3;
    if (score > bestScore) {
      bestScore = score;
      bestIdx = i;
    }
  }

  let mixOut = bestIdx * HOP_SEC;
  // Clamp: after 70% of track, before minTail from end.
  const earliest = duration * 0.7;
  const latest = Math.max(earliest, duration - minTailSec);
  mixOut = Math.min(latest, Math.max(earliest, mixOut));
  return { mixOut, fade, silent };
}

/**
 * Mix-in: first sustained body-level groove.
 * A short lift inside a breakdown (8–12 dB under the chorus) is not a cue —
 * landing there makes the drop slam in after the blend.
 */
function detectMixIn(energy: number[], vocal: number[], duration: number): number {
  const n = energy.length;
  void vocal;
  if (n < 8 || duration < 45) return 0;

  const headEnd = Math.min(n - 16, Math.floor(Math.min(72, duration * 0.45) / HOP_SEC));
  const body = meanSlice(energy, n * 0.3, n * 0.75);
  const thresh = Math.max(0.28, body * 0.58);

  for (let i = 1; i < headEnd; i++) {
    const next = meanSlice(energy, i, i + 8); // ~2s
    const hold = meanSlice(energy, i, i + 16); // ~4s, rejects one-bar bumps
    if (next >= thresh && hold >= thresh * 0.9) {
      return Math.min(duration * 0.45, i * HOP_SEC);
    }
  }
  return Math.min(32, duration > 180 ? 16 : 8);
}

/**
 * Beat-grid phase from a low-passed onset in the body of the track.
 * `downbeatSec` is in `[0, 60/bpm)`. Confidence stays low on noise.
 */
export function estimateDownbeat(
  samples: Float32Array,
  sampleRate: number,
  bpm: number
): { downbeatSec: number; confidence: number } {
  const none = { downbeatSec: 0, confidence: 0 };
  if (!(bpm > 40 && bpm < 220) || !(sampleRate > 1000) || samples.length < 64) return none;

  const hopSec = 0.01;
  const hop = Math.max(1, Math.floor(sampleRate * hopSec));
  const beatSec = 60 / bpm;
  const beatHop = Math.round(beatSec / hopSec);
  if (beatHop < 8 || beatHop > 500) return none;

  const duration = samples.length / sampleRate;
  const winSec = Math.min(16, Math.max(0, duration - 0.25));
  if (winSec < beatSec * 8) return none;
  const startSec = Math.min(Math.max(0, duration * 0.2), Math.max(0, duration - winSec));
  const startSample = Math.floor(startSec * sampleRate);
  const endSample = Math.min(samples.length, startSample + Math.floor(winSec * sampleRate));
  const nHops = Math.floor((endSample - startSample) / hop);
  if (nHops < beatHop * 8) return none;

  const env = new Float32Array(nHops);
  const alpha = 1 - Math.exp((-2 * Math.PI * 180) / sampleRate);
  let y = 0;
  let s = startSample;
  for (let h = 0; h < nHops; h++) {
    let e = 0;
    const hEnd = s + hop;
    for (; s < hEnd; s++) {
      const x = samples[s] ?? 0;
      y += alpha * (x - y);
      e += y * y;
    }
    env[h] = Math.sqrt(e / hop);
  }
  const onset = new Float32Array(nHops);
  for (let i = 1; i < nHops; i++) onset[i] = Math.max(0, (env[i] ?? 0) - (env[i - 1] ?? 0));

  const scores = new Float64Array(beatHop);
  for (let off = 0; off < beatHop; off++) {
    let sum = 0;
    let n = 0;
    for (let i = off; i < nHops; i += beatHop) {
      sum += onset[i] ?? 0;
      if (i + 1 < nHops) sum += 0.35 * (onset[i + 1] ?? 0);
      n++;
    }
    scores[off] = n ? sum / n : 0;
  }

  let bestOff = 0;
  let best = -1;
  let total = 0;
  for (let i = 0; i < beatHop; i++) {
    const v = scores[i] ?? 0;
    total += v;
    if (v > best) {
      best = v;
      bestOff = i;
    }
  }
  if (!(best > 1e-8)) return none;

  const sorted = Array.from(scores).sort((a, b) => a - b);
  const median = sorted[sorted.length >> 1] ?? 0;
  const p75 = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.75))] ?? 0;
  const offBeat = scores[(bestOff + (beatHop >> 1)) % beatHop] ?? 0;
  const contrast = (best - median) / best;
  const peakiness = (best - p75) / best;
  const ratio = best / (offBeat + 1e-12);
  let confidence = 0;
  // No floor: a barely-peaked onset (noise) must stay under the planner gate.
  if (peakiness >= 0.35 && ratio >= 1.45 && contrast >= 0.28) {
    const p = Math.min(1, (peakiness - 0.35) / 0.4);
    const r = Math.min(1, (ratio - 1.45) / 1.15);
    confidence = Math.min(1, p * 0.72 + r * 0.28);
  }
  const mean = total / beatHop;
  if (best < mean * 1.6) confidence = Math.min(confidence, 0.34);

  const y0 = scores[(bestOff - 1 + beatHop) % beatHop] ?? 0;
  const y1 = scores[bestOff] ?? 0;
  const y2 = scores[(bestOff + 1) % beatHop] ?? 0;
  const denom = y0 - 2 * y1 + y2;
  let delta = 0;
  if (denom !== 0) {
    delta = (0.5 * (y0 - y2)) / denom;
    if (delta > 0.5) delta = 0.5;
    if (delta < -0.5) delta = -0.5;
  }
  let downbeatSec = startSec + (bestOff + delta) * hopSec;
  downbeatSec = ((downbeatSec % beatSec) + beatSec) % beatSec;
  return { downbeatSec, confidence };
}

function tempoStability(energy: number[], bpm: number): number {
  if (!(bpm > 30) || energy.length < 16) return 0.4;
  const period = 60 / bpm / HOP_SEC;
  if (period < 2) return 0.4;
  const onset = onsetEnvelope(energy);
  let hits = 0;
  let checks = 0;
  for (let i = period; i < onset.length; i += period) {
    const idx = Math.round(i);
    const window = onset.slice(Math.max(0, idx - 1), Math.min(onset.length, idx + 2));
    const peak = Math.max(...window, 0);
    const mean = onset.reduce((a, b) => a + b, 0) / onset.length;
    checks++;
    if (peak > mean * 1.2) hits++;
  }
  return checks ? Math.min(1, hits / checks) : 0.4;
}

export async function analyzeTrackBuffer(
  buffer: AudioBuffer,
  name: string,
  onProgress?: (msg: string) => void
): Promise<TrackAIProfile> {
  onProgress?.("Декод → mono…");
  await yieldToUI();
  const monoFull = monoFromBuffer(buffer);
  const sr = buffer.sampleRate;
  const analysisRate = 22_050;
  const mono = downsample(monoFull, sr, analysisRate);

  onProgress?.("Энергия / вокал…");
  await yieldToUI();
  const energy = energyCurve(mono, analysisRate);
  const vocal = vocalCurve(mono, analysisRate, energy);

  onProgress?.("BPM…");
  await yieldToUI();
  const tempo = estimateBPMFromSamples(mono, analysisRate);
  const stability = tempoStability(energy, tempo.bpm);
  const phase = estimateDownbeat(mono, analysisRate, tempo.bpm);

  onProgress?.("Key / Camelot…");
  await yieldToUI();
  const chroma = computeChroma(mono, analysisRate);
  const key = estimateCamelotKey(chroma);

  onProgress?.("Cue mixIn / mixOut…");
  await yieldToUI();
  const duration = buffer.duration;
  const out = detectMixOut(energy, vocal, duration);
  const mixIn = detectMixIn(energy, vocal, duration);

  const reason = [
    `BPM ${tempo.bpm} (conf ${(tempo.confidence * 100) | 0}%)`,
    key.camelot ? `Key ${key.camelot}` : "Key ?",
    `mixOut ${out.mixOut.toFixed(1)}s`,
    `mixIn ${mixIn.toFixed(1)}s`,
    phase.confidence >= 0.45
      ? `downbeat ${phase.downbeatSec.toFixed(3)}s (${(phase.confidence * 100) | 0}%)`
      : null,
    out.fade ? "fadeOut" : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return {
    name,
    durationSec: duration,
    bpm: tempo.bpm,
    bpmConfidence: tempo.confidence,
    camelotKey: key.camelot,
    keyConfidence: key.confidence,
    energy,
    vocalPresence: vocal,
    mixInSec: mixIn,
    mixOutSec: out.mixOut,
    hasFadeOut: out.fade,
    endsInSilence: out.silent,
    tempoStability: stability,
    downbeatSec: phase.downbeatSec,
    downbeatConfidence: phase.confidence,
    reason,
  };
}

function yieldToUI(): Promise<void> {
  return new Promise((r) => setTimeout(r, 0));
}
