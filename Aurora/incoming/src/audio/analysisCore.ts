// Чистый DSP-код без DOM — используется внутри Web Worker.
import type { Genre, TrackAnalysis } from "../types";

export interface RawAudio {
  samples: Float32Array; // моно
  sampleRate: number;
  duration: number;
}

/* ------------------------------ FFT ------------------------------ */
function fft(re: Float32Array, im: Float32Array) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let j = 0; j < len / 2; j++) {
        const ur = re[i + j], ui = im[i + j];
        const vr = re[i + j + len / 2] * cr - im[i + j + len / 2] * ci;
        const vi = re[i + j + len / 2] * ci + im[i + j + len / 2] * cr;
        re[i + j] = ur + vr; im[i + j] = ui + vi;
        re[i + j + len / 2] = ur - vr; im[i + j + len / 2] = ui - vi;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr; cr = ncr;
      }
    }
  }
}

const FFT_SIZE = 4096;
const hann = new Float32Array(FFT_SIZE).map((_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (FFT_SIZE - 1)));

function spectrum(samples: Float32Array, start: number): Float32Array {
  const re = new Float32Array(FFT_SIZE);
  const im = new Float32Array(FFT_SIZE);
  for (let i = 0; i < FFT_SIZE; i++) re[i] = (samples[start + i] ?? 0) * hann[i];
  fft(re, im);
  const mag = new Float32Array(FFT_SIZE / 2);
  for (let i = 0; i < FFT_SIZE / 2; i++) mag[i] = Math.hypot(re[i], im[i]);
  return mag;
}

/* --------------------------- Envelope / Onsets --------------------------- */
// 128 сэмплов при 22 кГц ≈ 172 кадра/с — точность темпа ~±0.2 BPM после интерполяции
const HOP = 128;

function envelope(samples: Float32Array): Float32Array {
  const frames = Math.floor(samples.length / HOP);
  const env = new Float32Array(frames);
  for (let f = 0; f < frames; f++) {
    let s = 0;
    const base = f * HOP;
    for (let i = 0; i < HOP; i++) { const v = samples[base + i]; s += v * v; }
    env[f] = Math.sqrt(s / HOP);
  }
  return env;
}

function onsetFunction(env: Float32Array): Float32Array {
  const onset = new Float32Array(env.length);
  for (let i = 1; i < env.length; i++) {
    const d = env[i] - env[i - 1];
    onset[i] = d > 0 ? d : 0;
  }
  // нормализация
  let max = 0;
  for (let i = 0; i < onset.length; i++) if (onset[i] > max) max = onset[i];
  if (max > 0) for (let i = 0; i < onset.length; i++) onset[i] /= max;
  return onset;
}

function detectTempo(onset: Float32Array, sampleRate: number) {
  const fps = sampleRate / HOP;
  const minLag = Math.floor((60 / 200) * fps);
  const maxLag = Math.ceil((60 / 60) * fps);
  const n = onset.length;
  let mean = 0;
  for (let i = 0; i < n; i++) mean += onset[i];
  mean /= n;
  const acf = new Float32Array(maxLag + 1);
  for (let lag = minLag; lag <= maxLag; lag++) {
    let s = 0;
    for (let i = 0; i + lag < n; i++) s += (onset[i] - mean) * (onset[i + lag] - mean);
    acf[lag] = s / (n - lag);
  }
  // Усиливаем лаги, у которых есть кратные пики (2x, 4x) — так надёжнее
  let bestLag = minLag, bestScore = -Infinity;
  for (let lag = minLag; lag <= maxLag; lag++) {
    let score = acf[lag];
    if (lag * 2 <= maxLag) score += 0.5 * acf[lag * 2];
    const half = Math.round(lag / 2);
    if (half >= minLag) score += 0.25 * acf[half];
    const bpm = (60 * fps) / lag;
    // Предпочитаем «человеческий» диапазон 80–160
    const prior = Math.exp(-Math.pow((Math.log2(bpm) - Math.log2(118)) / 0.55, 2));
    score *= 0.4 + prior;
    if (score > bestScore) { bestScore = score; bestLag = lag; }
  }
  // Параболическая интерполяция для точности
  let refined = bestLag;
  if (bestLag > minLag && bestLag < maxLag) {
    const a = acf[bestLag - 1], b = acf[bestLag], c = acf[bestLag + 1];
    const denom = a - 2 * b + c;
    if (Math.abs(denom) > 1e-9) refined = bestLag + (0.5 * (a - c)) / denom;
  }
  let bpm = (60 * fps) / refined;
  while (bpm < 70) bpm *= 2;
  while (bpm > 180) bpm /= 2;
  const period = (60 / bpm) * fps; // в кадрах

  // Фаза бита: где сумма onset по сетке максимальна
  const P = Math.round(period);
  let bestPhase = 0, bestSum = -1;
  for (let p = 0; p < P; p++) {
    let s = 0;
    for (let k = p; k < Math.min(n, p + P * 64); k += P) s += onset[k];
    if (s > bestSum) { bestSum = s; bestPhase = p; }
  }
  const beatOffset = bestPhase / fps;
  // «Танцевальность» — насколько выражена периодичность
  const peak = acf[bestLag];
  let acfMean = 0, cnt = 0;
  for (let lag = minLag; lag <= maxLag; lag++) { acfMean += Math.abs(acf[lag]); cnt++; }
  acfMean /= cnt || 1;
  const danceability = Math.max(0, Math.min(1, acfMean > 0 ? (peak / acfMean - 1) / 4 : 0));
  return { bpm, beatOffset, danceability };
}

/* ------------------------------ Tonality ------------------------------ */
const NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
const MAJOR_PROFILE = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const MINOR_PROFILE = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
const CAMELOT_MAJOR: Record<string, string> = { B: "1B", "F#": "2B", "C#": "3B", "G#": "4B", "D#": "5B", "A#": "6B", F: "7B", C: "8B", G: "9B", D: "10B", A: "11B", E: "12B" };
const CAMELOT_MINOR: Record<string, string> = { "G#": "1A", "D#": "2A", "A#": "3A", F: "4A", C: "5A", G: "6A", D: "7A", A: "8A", E: "9A", B: "10A", "F#": "11A", "C#": "12A" };

function correlation(a: number[], b: number[]) {
  const n = a.length;
  const ma = a.reduce((s, v) => s + v, 0) / n;
  const mb = b.reduce((s, v) => s + v, 0) / n;
  let num = 0, da = 0, db = 0;
  for (let i = 0; i < n; i++) {
    num += (a[i] - ma) * (b[i] - mb);
    da += (a[i] - ma) ** 2;
    db += (b[i] - mb) ** 2;
  }
  return num / (Math.sqrt(da * db) || 1);
}

function analyzeSpectral(samples: Float32Array, sampleRate: number) {
  const frames = 48;
  const step = Math.max(1, Math.floor((samples.length - FFT_SIZE) / frames));
  const chroma = new Array(12).fill(0);
  let centroidSum = 0, centroidCount = 0;
  const binHz = sampleRate / FFT_SIZE;
  for (let f = 0; f < frames; f++) {
    const start = f * step;
    if (start + FFT_SIZE > samples.length) break;
    const mag = spectrum(samples, start);
    let num = 0, den = 0;
    for (let b = 1; b < mag.length; b++) {
      const hz = b * binHz;
      num += hz * mag[b]; den += mag[b];
      if (hz >= 60 && hz <= 4000) {
        const midi = 69 + 12 * Math.log2(hz / 440);
        const pc = ((Math.round(midi) % 12) + 12) % 12;
        chroma[pc] += mag[b] * mag[b];
      }
    }
    if (den > 0) { centroidSum += num / den; centroidCount++; }
  }
  const centroid = centroidCount ? centroidSum / centroidCount : 1000;
  // яркость: 500Hz -> 0, 5000Hz -> 1 (лог-шкала)
  const brightness = Math.max(0, Math.min(1, (Math.log2(centroid) - Math.log2(500)) / (Math.log2(5000) - Math.log2(500))));

  let bestKey = "C", bestMode: "major" | "minor" = "major", best = -Infinity;
  for (let i = 0; i < 12; i++) {
    const rotated = chroma.map((_, k) => chroma[(k + i) % 12]);
    const cMaj = correlation(rotated, MAJOR_PROFILE);
    const cMin = correlation(rotated, MINOR_PROFILE);
    if (cMaj > best) { best = cMaj; bestKey = NOTE_NAMES[i]; bestMode = "major"; }
    if (cMin > best) { best = cMin; bestKey = NOTE_NAMES[i]; bestMode = "minor"; }
  }
  const key = `${bestKey} ${bestMode}`;
  const camelot = bestMode === "major" ? CAMELOT_MAJOR[bestKey] : CAMELOT_MINOR[bestKey];
  return { brightness, key, camelot };
}

/* ------------------------------ Genre heuristic ------------------------------ */
function guessGenre(bpm: number, energy: number, brightness: number, dance: number): Genre {
  if (energy < 0.18 && dance < 0.25) return "Ambient";
  if (bpm >= 160) return "Drum & Bass";
  if (bpm >= 136 && bpm < 160) return brightness > 0.55 ? "Trance" : "Techno";
  if (bpm >= 126 && bpm < 136) return energy > 0.5 ? "Techno" : "House";
  if (bpm >= 116 && bpm < 126) return dance > 0.4 ? "House" : "Pop";
  if (bpm >= 100 && bpm < 116) return brightness > 0.5 ? "Pop" : "Rock";
  if (bpm >= 70 && bpm < 100) return brightness < 0.4 && energy < 0.5 ? "Lo-Fi" : "Hip-Hop";
  return "Unknown";
}

/* ------------------------------ Main ------------------------------ */
export function analyzeAudio(raw: RawAudio): TrackAnalysis {
  const { samples, sampleRate, duration } = raw;
  const env = envelope(samples);

  // Waveform для UI
  const WF = 160;
  const waveform: number[] = [];
  const per = Math.max(1, Math.floor(env.length / WF));
  let wfMax = 0;
  for (let i = 0; i < WF; i++) {
    let m = 0;
    for (let k = 0; k < per; k++) m = Math.max(m, env[i * per + k] ?? 0);
    waveform.push(m); if (m > wfMax) wfMax = m;
  }
  for (let i = 0; i < waveform.length; i++) waveform[i] = wfMax ? waveform[i] / wfMax : 0;

  // Громкость / энергия
  let rmsSum = 0;
  for (let i = 0; i < env.length; i++) rmsSum += env[i] * env[i];
  const rms = Math.sqrt(rmsSum / (env.length || 1));
  const loudnessDb = 20 * Math.log10(rms || 1e-6);
  const energy = Math.max(0, Math.min(1, (loudnessDb + 36) / 30)); // -36dB..-6dB -> 0..1

  // Темп на средней части (до 100 с) — там самый стабильный грув
  const fps = sampleRate / HOP;
  const analyzeFrames = Math.min(env.length, Math.floor(fps * 100));
  const startFrame = Math.max(0, Math.floor((env.length - analyzeFrames) / 2));
  const onset = onsetFunction(env.subarray(startFrame, startFrame + analyzeFrames));
  const tempo = detectTempo(onset, sampleRate);
  // фаза считалась от startFrame — приводим к началу трека
  const beatSec = 60 / tempo.bpm;
  let beatOffset = startFrame / fps + tempo.beatOffset;
  beatOffset = beatOffset - Math.floor(beatOffset / beatSec) * beatSec;

  // Точки микса по огибающей (сглаженной ~1 с)
  const win = Math.round(fps);
  const smooth = new Float32Array(env.length);
  let acc = 0;
  for (let i = 0; i < env.length; i++) {
    acc += env[i]; if (i >= win) acc -= env[i - win];
    smooth[i] = acc / Math.min(i + 1, win);
  }
  const sorted = Array.from(smooth).sort((a, b) => a - b);
  const median = sorted[Math.floor(sorted.length / 2)] || 0;
  const thr = median * 0.55;
  let inFrame = 0;
  while (inFrame < smooth.length && smooth[inFrame] < thr) inFrame++;
  let outFrame = smooth.length - 1;
  while (outFrame > 0 && smooth[outFrame] < thr) outFrame--;
  let mixIn = inFrame / fps;
  let mixOut = outFrame / fps;
  // выравниваем по сетке битов
  mixIn = beatOffset + Math.max(0, Math.round((mixIn - beatOffset) / beatSec)) * beatSec;
  mixOut = Math.min(mixOut, duration - 1);
  mixOut = beatOffset + Math.floor((mixOut - beatOffset) / beatSec) * beatSec;
  if (mixOut - mixIn < 8) { mixIn = Math.min(mixIn, 0); mixOut = Math.max(mixIn + 8, duration - 2); }

  const spectral = analyzeSpectral(samples, sampleRate);
  const genre = guessGenre(tempo.bpm, energy, spectral.brightness, tempo.danceability);

  return {
    bpm: Math.round(tempo.bpm * 10) / 10,
    beatOffset,
    energy,
    brightness: spectral.brightness,
    danceability: tempo.danceability,
    key: spectral.key,
    camelot: spectral.camelot,
    mixIn,
    mixOut,
    genre,
    loudnessDb,
    waveform,
  };
}
