/** Offline per-track analysis (Apple Automix–style cues + BPM). */

export type TrackAIProfile = {
  name: string;
  durationSec: number;
  bpm: number;
  bpmConfidence: number;
  energy: number[]; // ~1 sample / 0.25s, 0…1
  vocalPresence: number[]; // mid-band proxy per energy hop
  mixInSec: number;
  mixOutSec: number;
  hasFadeOut: boolean;
  endsInSilence: boolean;
  tempoStability: number;
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

/**
 * BPM via autocorrelation of onset envelope in 70–180 range.
 * Mirrors the spirit of TrackAnalyzer TempoDetector (lab port).
 */
export function estimateBPM(energy: number[], hopSec = HOP_SEC): { bpm: number; confidence: number } {
  const onset = onsetEnvelope(energy);
  if (onset.length < 32) return { bpm: 120, confidence: 0.1 };

  const minBpm = 70;
  const maxBpm = 180;
  const minLag = Math.max(2, Math.round(60 / maxBpm / hopSec));
  const maxLag = Math.min(onset.length >> 1, Math.round(60 / minBpm / hopSec));

  let bestLag = minLag;
  let bestScore = -1;
  const scores: number[] = [];
  for (let lag = minLag; lag <= maxLag; lag++) {
    let corr = 0;
    let norm = 0;
    for (let i = 0; i + lag < onset.length; i++) {
      corr += onset[i]! * onset[i + lag]!;
      norm += onset[i]! * onset[i]!;
    }
    const score = norm > 1e-9 ? corr / norm : 0;
    scores.push(score);
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }

  let bpm = 60 / (bestLag * hopSec);
  // Prefer ~100–140 by folding
  while (bpm < 80) bpm *= 2;
  while (bpm > 160) bpm /= 2;

  const mean = scores.reduce((a, b) => a + b, 0) / Math.max(1, scores.length);
  const confidence = Math.min(1, Math.max(0.15, (bestScore - mean) * 4 + 0.35));
  return { bpm: Math.round(bpm * 10) / 10, confidence };
}

function meanSlice(values: number[], from: number, to: number): number {
  const a = Math.max(0, Math.floor(from));
  const b = Math.min(values.length, Math.ceil(to));
  if (b <= a) return 0;
  let s = 0;
  for (let i = a; i < b; i++) s += values[i]!;
  return s / (b - a);
}

/** Mix-out: start of outro — last sustained quieter / instrumental region near the end. */
function detectMixOut(energy: number[], vocal: number[], duration: number): { mixOut: number; fade: boolean; silent: boolean } {
  const n = energy.length;
  if (n < 8) return { mixOut: Math.max(0, duration - 16), fade: false, silent: false };

  const floor = Math.floor(n * 0.75);
  const tail = energy.slice(Math.floor(n * 0.85));
  const silent = meanSlice(energy, n * 0.92, n) < 0.08;
  const fade = meanSlice(energy, n * 0.7, n * 0.85) > meanSlice(energy, n * 0.9, n) * 1.35;

  // Find earliest point in last 25% where energy stays below mid-track average * 0.85
  // OR vocal drops (instrumental outro) while energy remains.
  const bodyMean = meanSlice(energy, n * 0.2, n * 0.6);
  const vocalBody = meanSlice(vocal, n * 0.2, n * 0.6);

  let mixIdx = floor;
  for (let i = floor; i < n - 4; i++) {
    const localE = meanSlice(energy, i, i + 4);
    const localV = meanSlice(vocal, i, i + 4);
    const instrumentalOutro = localV < vocalBody * 0.55 && localE > 0.12;
    const softOutro = localE < bodyMean * 0.75;
    if (instrumentalOutro || softOutro) {
      mixIdx = i;
      break;
    }
  }

  // Prefer ~8–16s before end when track is long
  const sec = mixIdx * HOP_SEC;
  const minPlayed = duration * 0.75;
  const idealTail = duration > 140 ? 24 : 16;
  const capped = Math.min(sec, Math.max(minPlayed, duration - idealTail));
  const mixOut = Math.max(minPlayed, Math.min(capped, duration - 6));
  void tail;
  return { mixOut, fade, silent };
}

/** Mix-in: skip padded intro — first sustained energy after quiet head. */
function detectMixIn(energy: number[], vocal: number[], duration: number): number {
  const n = energy.length;
  if (n < 8 || duration < 90) return 0;

  const headEnd = Math.min(n, Math.floor((Math.min(48, duration * 0.25)) / HOP_SEC));
  const body = meanSlice(energy, n * 0.25, n * 0.5);

  for (let i = 2; i < headEnd - 4; i++) {
    const prev = meanSlice(energy, 0, i);
    const next = meanSlice(energy, i, i + 6);
    const vNext = meanSlice(vocal, i, i + 6);
    // Rise into the groove / vocal
    if (next > Math.max(0.2, body * 0.55) && next > prev * 1.35 && (vNext > 0.25 || next > 0.35)) {
      return Math.min(duration * 0.25, i * HOP_SEC);
    }
  }
  // Fallback: 4–8 bars @ ~120
  return Math.min(32, duration > 180 ? 16 : 8);
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
  const tempo = estimateBPM(energy);
  const stability = tempoStability(energy, tempo.bpm);

  onProgress?.("Cue mixIn / mixOut…");
  await yieldToUI();
  const duration = buffer.duration;
  const out = detectMixOut(energy, vocal, duration);
  const mixIn = detectMixIn(energy, vocal, duration);

  const reason = [
    `BPM ${tempo.bpm} (conf ${(tempo.confidence * 100) | 0}%)`,
    `mixOut ${out.mixOut.toFixed(1)}s`,
    `mixIn ${mixIn.toFixed(1)}s`,
    out.fade ? "fadeOut" : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return {
    name,
    durationSec: duration,
    bpm: tempo.bpm,
    bpmConfidence: tempo.confidence,
    energy,
    vocalPresence: vocal,
    mixInSec: mixIn,
    mixOutSec: out.mixOut,
    hasFadeOut: out.fade,
    endsInSilence: out.silent,
    tempoStability: stability,
    reason,
  };
}

function yieldToUI(): Promise<void> {
  return new Promise((r) => setTimeout(r, 0));
}
