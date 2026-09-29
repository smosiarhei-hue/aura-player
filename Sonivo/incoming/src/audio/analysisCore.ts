// Чистый DSP-код без DOM — используется внутри Web Worker.
import type { Genre, TrackAnalysis } from "../types";

export interface RawAudio {
  samples: Float32Array; // моно
  sampleRate: number;
  duration: number;
  hintBpm?: number;
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

/* --------------------------- Low-pass / Band-pass Filters for Kick & Snare --------------------------- */
function filterBiquad(samples: Float32Array, sampleRate: number, type: "lowpass" | "bandpass", freq: number, Q: number): Float32Array {
  const w0 = (2 * Math.PI * freq) / sampleRate;
  const cosw0 = Math.cos(w0);
  const sinw0 = Math.sin(w0);
  const alpha = sinw0 / (2 * Q);

  let b0 = 0, b1 = 0, b2 = 0, a0 = 1 + alpha, a1 = -2 * cosw0, a2 = 1 - alpha;
  if (type === "lowpass") {
    b0 = (1 - cosw0) / 2;
    b1 = 1 - cosw0;
    b2 = (1 - cosw0) / 2;
  } else {
    // bandpass (constant skirt gain)
    b0 = sinw0 / 2;
    b1 = 0;
    b2 = -sinw0 / 2;
  }

  const nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0;
  const na1 = a1 / a0, na2 = a2 / a0;

  const out = new Float32Array(samples.length);
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < samples.length; i++) {
    const x0 = samples[i];
    const y0 = nb0 * x0 + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2;
    x2 = x1; x1 = x0;
    y2 = y1; y1 = y0;
    out[i] = y0;
  }
  return out;
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

function detectTempoAndGrid(
  lowOnset: Float32Array,
  lowEnv: Float32Array,
  midHiOnset: Float32Array,
  fullOnset: Float32Array,
  sampleRate: number,
  hintBpm?: number
) {
  const fps = sampleRate / HOP;
  const minLag = Math.floor((60 / 210) * fps);
  const maxLag = Math.ceil((60 / 55) * fps);
  const n = lowOnset.length;

  // Комбинированный онсет с акцентом на бочку (75% бочка, 25% общий)
  const onset = new Float32Array(n);
  for (let i = 0; i < n; i++) onset[i] = lowOnset[i] * 0.75 + fullOnset[i] * 0.25;

  let mean = 0;
  for (let i = 0; i < n; i++) mean += onset[i];
  mean /= n;
  const acf = new Float32Array(maxLag + 1);
  for (let lag = minLag; lag <= maxLag; lag++) {
    let s = 0;
    for (let i = 0; i + lag < n; i++) s += (onset[i] - mean) * (onset[i + lag] - mean);
    acf[lag] = s / (n - lag);
  }

  let bpm = hintBpm && hintBpm >= 50 && hintBpm <= 220 ? hintBpm : 0;
  let bestLag = minLag;
  if (!bpm) {
    let bestScore = -Infinity;
    for (let lag = minLag; lag <= maxLag; lag++) {
      let score = acf[lag];
      if (lag * 2 <= maxLag) score += 0.5 * acf[lag * 2];
      const half = Math.round(lag / 2);
      if (half >= minLag) score += 0.25 * acf[half];
      if (score > bestScore) { bestScore = score; bestLag = lag; }
    }
    // Параболическая интерполяция для точности
    let refined = bestLag;
    if (bestLag > minLag && bestLag < maxLag) {
      const a = acf[bestLag - 1], b = acf[bestLag], c = acf[bestLag + 1];
      const denom = a - 2 * b + c;
      if (Math.abs(denom) > 1e-9) refined = bestLag + (0.5 * (a - c)) / denom;
    }
    bpm = (60 * fps) / refined;
    while (bpm < 65) bpm *= 2;
    while (bpm > 195) bpm /= 2;
  } else {
    bestLag = Math.min(maxLag, Math.max(minLag, Math.round((60 * fps) / bpm)));
  }

  // Если BPM находится в пределах ±0.15 от целого числа (стандарт для DAW),
  // привязываем к точному целому значению, предотвращая накопление фазовой погрешности
  const roundedInt = Math.round(bpm);
  if (Math.abs(bpm - roundedInt) < 0.16) {
    bpm = roundedInt;
  } else {
    bpm = Math.round(bpm * 10) / 10;
  }

  const period = (60 / bpm) * fps; // Точный период бита в кадрах (дробный!)

  // 1. Поиск точной фазы бита (0..period) с субкадровым разрешением без целочисленного сноса
  let bestPhase = 0, bestSum = -1;
  const maxBeats = Math.floor((n - period * 2) / period);
  for (let p = 0; p < period; p += 0.5) {
    let s = 0;
    for (let k = 0; k < maxBeats; k++) {
      const idx = Math.round(p + k * period);
      if (idx < n) s += lowOnset[idx] * 1.5 + onset[idx];
    }
    if (s > bestSum) { bestSum = s; bestPhase = p; }
  }

  // 2. Определение сильной доли такта (True Downbeat: Бит 1 из 4/4)
  // В 4/4 такте 4 кандидата: b = 0, 1, 2, 3.
  // Сильная доля (Бит 1) характеризуется мощным ударом бочки и баса,
  // в то время как биты 2 и 4 содержат снейр/хлопок (midHi).
  const barPeriod = period * 4;
  const numBars = Math.floor((n - bestPhase - barPeriod) / barPeriod);
  const barScores = [0, 0, 0, 0];

  for (let b = 0; b < 4; b++) {
    let score = 0;
    for (let j = 0; j < numBars; j++) {
      const f1 = Math.round(bestPhase + (j * 4 + b) * period);
      const f2 = Math.round(bestPhase + (j * 4 + b + 1) * period);
      const f3 = Math.round(bestPhase + (j * 4 + b + 2) * period);
      const f4 = Math.round(bestPhase + (j * 4 + b + 3) * period);
      if (f4 < n) {
        const kick1 = (lowOnset[f1] ?? 0) * 2.0 + (lowEnv[f1] ?? 0) * 1.2;
        const snare2 = midHiOnset[f2] ?? 0;
        const kick3 = (lowOnset[f3] ?? 0) * 1.0;
        const snare4 = midHiOnset[f4] ?? 0;
        score += kick1 + (snare2 + snare4) * 1.4 + kick3 * 0.6;
      }
    }
    barScores[b] = score;
  }

  let bestBeatIdx = 0, maxBarScore = -Infinity;
  for (let b = 0; b < 4; b++) {
    if (barScores[b] > maxBarScore) {
      maxBarScore = barScores[b];
      bestBeatIdx = b;
    }
  }

  // Смещение даунбита относительно начала анализируемого фрагмента
  const downbeatPhaseFrames = bestPhase + bestBeatIdx * period;
  const downbeatOffset = downbeatPhaseFrames / fps;

  // «Танцевальность» — выраженность периодичности
  const peak = acf[bestLag] || 0;
  let acfMean = 0, cnt = 0;
  for (let lag = minLag; lag <= maxLag; lag++) { acfMean += Math.abs(acf[lag]); cnt++; }
  acfMean /= cnt || 1;
  const danceability = Math.max(0, Math.min(1, acfMean > 0 ? (peak / acfMean - 1) / 4 : 0.3));

  return { bpm, downbeatOffset, danceability };
}

/* ------------------------------ Tonality ------------------------------ */
const NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
const CAMELOT_MAJOR: Record<string, string> = { B: "1B", "F#": "2B", "C#": "3B", "G#": "4B", "D#": "5B", "A#": "6B", F: "7B", C: "8B", G: "9B", D: "10B", A: "11B", E: "12B" };
const CAMELOT_MINOR: Record<string, string> = { "G#": "1A", "D#": "2A", "A#": "3A", F: "4A", C: "5A", G: "6A", D: "7A", A: "8A", E: "9A", B: "10A", "F#": "11A", "C#": "12A" };

// Sha'ath profiles (industry standard for electronic and popular music)
const SHAATH_MAJOR = [1.0, 0.05, 0.35, 0.05, 0.65, 0.40, 0.05, 0.85, 0.05, 0.45, 0.05, 0.30];
const SHAATH_MINOR = [1.0, 0.05, 0.35, 0.80, 0.05, 0.40, 0.05, 0.80, 0.45, 0.05, 0.50, 0.10];

// Krumhansl-Schmuckler profiles
const KS_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const KS_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

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
  const chroma = new Array(12).fill(0);
  let centroidSum = 0, centroidCount = 0;
  const N = FFT_SIZE;
  const step = Math.max(N, Math.floor(sampleRate * 0.75)); // шаг каждые 0.75с для устойчивого охвата трека

  for (let offset = 0; offset + N < samples.length; offset += step) {
    // 1. Спектральный центроид для тембральной яркости
    const mag = spectrum(samples, offset);
    let num = 0, den = 0;
    const binHz = sampleRate / N;
    const maxB = Math.min(mag.length, Math.floor(4000 / binHz));
    for (let b = 1; b < maxB; b++) {
      const hz = b * binHz;
      num += hz * mag[b];
      den += mag[b];
    }
    if (den > 0) { centroidSum += num / den; centroidCount++; }

    // 2. Прямой гармонический анализ 12 полутонов по октавам 2..6
    for (let pc = 0; pc < 12; pc++) {
      for (let oct = 2; oct <= 6; oct++) {
        const midi = pc + oct * 12;
        const freq = 440 * Math.pow(2, (midi - 69) / 12);
        const k = Math.round((N * freq) / sampleRate);
        const omega = (2 * Math.PI * k) / N;
        let real = 0, imag = 0;
        for (let i = 0; i < N; i += 2) {
          const w = 0.5 * (1 - Math.cos((2 * Math.PI * i) / (N - 1)));
          const s = (samples[offset + i] ?? 0) * w;
          real += s * Math.cos(omega * i);
          imag -= s * Math.sin(omega * i);
        }
        chroma[pc] += (real * real + imag * imag);
      }
    }
  }

  const centroid = centroidCount ? centroidSum / centroidCount : 1000;
  // яркость: 500Hz -> 0, 5000Hz -> 1 (лог-шкала)
  const brightness = Math.max(0, Math.min(1, (Math.log2(centroid) - Math.log2(500)) / (Math.log2(5000) - Math.log2(500))));

  const maxChroma = Math.max(...chroma, 1e-6);
  const normChroma = chroma.map((v) => v / maxChroma);

  let bestKey = "C", bestMode: "major" | "minor" = "major", best = -Infinity;
  for (let i = 0; i < 12; i++) {
    const rotated = normChroma.map((_, k) => normChroma[(k + i) % 12]);
    const sMaj = (correlation(rotated, SHAATH_MAJOR) + correlation(rotated, KS_MAJOR)) / 2;
    const sMin = (correlation(rotated, SHAATH_MINOR) + correlation(rotated, KS_MINOR)) / 2;
    if (sMaj > best) { best = sMaj; bestKey = NOTE_NAMES[i]; bestMode = "major"; }
    if (sMin > best) { best = sMin; bestKey = NOTE_NAMES[i]; bestMode = "minor"; }
  }
  const key = `${bestKey} ${bestMode}`;
  const camelot = bestMode === "major" ? CAMELOT_MAJOR[bestKey] : CAMELOT_MINOR[bestKey];
  return { brightness, key, camelot };
}

/* ------------------------------ Genre heuristic ------------------------------ */
function guessGenre(bpm: number, energy: number, brightness: number, dance: number): Genre {
  if (energy < 0.18 && dance < 0.25) return "Ambient";
  if (bpm >= 160) return "Drum & Bass";
  if (bpm >= 135 && bpm < 160) {
    if (brightness < 0.48) return "Hip-Hop";
    return brightness > 0.62 ? "Trance" : "Techno";
  }
  if (bpm >= 126 && bpm < 135) return energy > 0.6 ? "Techno" : "House";
  if (bpm >= 116 && bpm < 126) return dance > 0.4 ? "House" : "Pop";
  if (bpm >= 100 && bpm < 116) return brightness > 0.5 ? "Pop" : "Rock";
  if (bpm >= 65 && bpm < 100) return brightness < 0.4 && energy < 0.5 ? "Lo-Fi" : "Hip-Hop";
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

  // Выделяем низкочастотную составляющую (бочка/саб-бас до 160 Гц) и снейр/хлопок (полоса 2.5 кГц)
  const lowSamples = filterBiquad(samples, sampleRate, "lowpass", 160, 0.707);
  const midHiSamples = filterBiquad(samples, sampleRate, "bandpass", 2500, 1.0);
  const lowEnv = envelope(lowSamples);
  const midHiEnv = envelope(midHiSamples);

  // Темп и даунбит на средней части (до 100 с) — там самый стабильный грув трека
  const fps = sampleRate / HOP;
  const analyzeFrames = Math.min(env.length, Math.floor(fps * 100));
  const startFrame = Math.max(0, Math.floor((env.length - analyzeFrames) / 2));

  const lowSubEnv = lowEnv.subarray(startFrame, startFrame + analyzeFrames);
  const lowOnset = onsetFunction(lowSubEnv);
  const midHiOnset = onsetFunction(midHiEnv.subarray(startFrame, startFrame + analyzeFrames));
  const fullOnset = onsetFunction(env.subarray(startFrame, startFrame + analyzeFrames));

  const grid = detectTempoAndGrid(lowOnset, lowSubEnv, midHiOnset, fullOnset, sampleRate, raw.hintBpm);

  // Переводим смещение сильной доли (True Downbeat: Бит 1 такта 4/4) к началу трека
  const beatSec = 60 / grid.bpm;
  const barSec = beatSec * 4;
  let downbeatOffset = (startFrame / fps + grid.downbeatOffset) % barSec;
  downbeatOffset = ((downbeatOffset % barSec) + barSec) % barSec;
  const beatOffset = downbeatOffset;

  // --- Интеллектуальный поиск музыкальной структуры (Дропы, Ямы, Разгоны) ---
  const win = Math.round(fps);
  const smooth = new Float32Array(env.length);
  let acc = 0;
  for (let i = 0; i < env.length; i++) {
    acc += env[i]; if (i >= win) acc -= env[i - win];
    smooth[i] = acc / Math.min(i + 1, win);
  }
  const sorted = Array.from(smooth).sort((a, b) => a - b);
  const p95 = sorted[Math.floor(sorted.length * 0.95)] || 1e-4;
  const median = sorted[Math.floor(sorted.length * 0.5)] || 1e-4;

  const snapToBar = (sec: number) => {
    return beatOffset + Math.round((sec - beatOffset) / barSec) * barSec;
  };

  const deltaWindow = Math.round(fps * 1.5);
  const drops: number[] = [];
  const breakdowns: number[] = [];
  const buildUps: number[] = [];

  for (let i = deltaWindow; i < smooth.length - deltaWindow; i += Math.round(fps * 0.4)) {
    const prevE = smooth[i - deltaWindow] / p95;
    const curE = smooth[i] / p95;
    const diff = curE - prevE;
    const t = i / fps;

    // Резкий взрыв энергии = ДРОП / КУЛЬМИНАЦИЯ
    if (diff > 0.20 && curE > 0.42) {
      const snapped = snapToBar(t);
      if (snapped > 4 && snapped < duration - 8 && !drops.some((d) => Math.abs(d - snapped) < 10)) {
        drops.push(snapped);
      }
    }
    // Резкий спад энергии = БРЕЙКДАУН / ЯМА
    else if (diff < -0.22 && curE < 0.55) {
      const snapped = snapToBar(t);
      if (snapped > 12 && snapped < duration - 8 && !breakdowns.some((b) => Math.abs(b - snapped) < 10)) {
        breakdowns.push(snapped);
      }
    }
  }

  // Билдапы (за 2-4 такта до каждого дропа)
  for (const drop of drops) {
    const bStart = Math.max(0, snapToBar(drop - barSec * 2));
    if (!buildUps.some((b) => Math.abs(b - bStart) < 6)) {
      buildUps.push(bStart);
    }
  }

  // Выделяем голосовой диапазон (форманты вокала 400..3200 Гц)
  const vocalSamples = filterBiquad(samples, sampleRate, "bandpass", 1400, 0.8);
  const vocalEnv = envelope(vocalSamples);

  // Фразовая сетка (1 фраза / квадрат = 8 тактов = 32 бита)
  const phraseSec = barSec * 8;
  const snapToPhrase = (sec: number) => {
    return beatOffset + Math.round((sec - beatOffset) / phraseSec) * phraseSec;
  };

  // Поиск момента вступления вокала в интро (vocalStart)
  let vocalStart: number | undefined;
  const maxIntroSec = Math.min(duration * 0.40, 60);
  const introBars = Math.floor(maxIntroSec / barSec);
  let baseVocalLevel = 0;
  for (let b = 0; b < Math.min(2, introBars); b++) {
    const f0 = Math.round(((beatOffset + b * barSec) * fps));
    const f1 = Math.round(((beatOffset + (b + 1) * barSec) * fps));
    if (f1 <= vocalEnv.length) {
      for (let f = f0; f < f1; f++) baseVocalLevel += vocalEnv[f] || 0;
      baseVocalLevel /= Math.max(1, f1 - f0);
    }
  }

  for (let b = 1; b < introBars; b++) {
    const tBar = beatOffset + b * barSec;
    const f0 = Math.round(tBar * fps);
    const f1 = Math.round((tBar + barSec) * fps);
    if (f1 <= vocalEnv.length) {
      let barVocal = 0;
      for (let f = f0; f < f1; f++) barVocal += vocalEnv[f] || 0;
      barVocal /= Math.max(1, f1 - f0);
      if (barVocal > baseVocalLevel * 2.2 && barVocal > 0.08) {
        vocalStart = snapToBar(tBar);
        break;
      }
    }
  }

  // Поиск момента окончания вокала перед аутро (vocalEnd):
  // Сканируем финальную треть трека (от 68% до конца), чтобы найти, где замолкает голос солиста
  let vocalEnd: number | undefined;
  const outroScanSec = Math.max(duration * 0.68, duration - barSec * 36);
  const totalBars = Math.floor(duration / barSec);
  for (let b = totalBars - 2; b >= Math.floor(outroScanSec / barSec); b--) {
    const tBar = beatOffset + b * barSec;
    const f0 = Math.round(tBar * fps);
    const f1 = Math.round((tBar + barSec) * fps);
    if (f1 <= vocalEnv.length) {
      let barVocal = 0;
      for (let f = f0; f < f1; f++) barVocal += vocalEnv[f] || 0;
      barVocal /= Math.max(1, f1 - f0);
      if (barVocal > Math.max(0.09, baseVocalLevel * 1.5)) {
        vocalEnd = snapToBar(tBar + barSec);
        break;
      }
    }
  }

  // --- ИИ-подбор точек для Мэшапа (mixIn / mixOut) под вокал и фразы 4/4 ---
  // 1. Входящий трек B:
  // Если вокал вступает позже интро (например, на 16 или 32 сек),
  // начинаем микс так, чтобы разгон трека B сыграл в инструментальной части,
  // а его вокал или дроп вступил РОВНО на сильную долю развязки (t1)!
  let mixIn = 0;
  const earlyDrop = drops.find((d) => d >= barSec * 4 && d <= 75);
  if (vocalStart && vocalStart >= barSec * 4) {
    const leadBars = vocalStart >= barSec * 8 ? 8 : 4;
    mixIn = Math.max(0, snapToBar(vocalStart - barSec * leadBars));
  } else if (earlyDrop) {
    const leadBars = earlyDrop >= barSec * 8 ? 8 : (earlyDrop >= barSec * 4 ? 4 : 2);
    mixIn = Math.max(0, snapToBar(earlyDrop - barSec * leadBars));
  } else {
    const activeThr = median * 0.40;
    let firstActiveFrame = 0;
    while (firstActiveFrame < smooth.length && smooth[firstActiveFrame] < activeThr) firstActiveFrame++;
    mixIn = snapToPhrase(firstActiveFrame / fps);
  }

  // 2. Уходящий трек A (mixOut):
  // Золотое правило AutoMix: песня ОБЯЗАНА сыграть свои куплеты и кульминации (минимум 75% трека!).
  // Сведение начинается строго в АУТРО — когда закончился последний вокал или наступает аутро-яма.
  const minMixOutSec = Math.max(duration * 0.75, duration - barSec * 24);
  const maxMixOutSec = duration - barSec * 6;
  const outroBars = duration > 140 ? 16 : 8;
  let mixOut = snapToPhrase(duration - barSec * outroBars);

  // Ищем аутро-яму (breakdown) в финальной части песни:
  const outroBreakdown = breakdowns.filter((b) => b >= minMixOutSec && b <= maxMixOutSec).pop();

  if (vocalEnd && vocalEnd >= minMixOutSec && vocalEnd <= maxMixOutSec) {
    // Вокал закончился в аутро — идеальный момент для входа следующего трека!
    mixOut = snapToBar(vocalEnd);
  } else if (outroBreakdown) {
    // В аутро наступила яма (kick ушёл) — красивый естественный рубеж для сведения:
    mixOut = snapToBar(outroBreakdown);
  } else {
    // Сведение по 16-тактовой (или 8-тактовой) фразовой сетке аутро:
    mixOut = snapToPhrase(duration - barSec * outroBars);
  }

  // Защита: сведение никогда не начнется раньше 75% песни и оставит минимум 6 тактов на завершение
  mixIn = Math.max(0, Math.min(mixIn, duration - 10));
  mixOut = Math.max(minMixOutSec, Math.min(mixOut, maxMixOutSec));
  mixOut = snapToBar(mixOut);

  const spectral = analyzeSpectral(samples, sampleRate);
  const genre = guessGenre(grid.bpm, energy, spectral.brightness, grid.danceability);

  return {
    bpm: Math.round(grid.bpm * 10) / 10,
    beatOffset,
    energy,
    brightness: spectral.brightness,
    danceability: grid.danceability,
    key: spectral.key,
    camelot: spectral.camelot,
    mixIn,
    mixOut,
    drops,
    breakdowns,
    buildUps,
    vocalStart,
    vocalEnd,
    genre,
    loudnessDb,
    waveform,
  };
}
