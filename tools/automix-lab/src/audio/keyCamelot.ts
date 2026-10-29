/**
 * Harmonic key → Camelot (port of Sonivo HarmonicKeyDetector + CamelotCompatibility).
 * Chroma via Goertzel at pitch-class frequencies; key via Krumhansl–Schmuckler.
 */

const MAJOR_PROFILE = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const MINOR_PROFILE = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
/** Index = pitch class C=0 … B=11 */
const MAJOR_CAMELOT = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"];
const MINOR_CAMELOT = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"];

export type HarmonicMatch = {
  isNaturallyCompatible: boolean;
  pitchShiftCents: number;
  isHarmonicallyViable: boolean;
  description: string;
};

export type KeyEstimate = {
  camelot: string | null;
  confidence: number;
};

function goertzelPower(frame: Float32Array, sampleRate: number, freq: number): number {
  const n = frame.length;
  if (n < 16) return 0;
  const w = (2 * Math.PI * freq) / sampleRate;
  const coeff = 2 * Math.cos(w);
  let s0 = 0;
  let s1 = 0;
  let s2 = 0;
  for (let i = 0; i < n; i++) {
    s0 = frame[i]! + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  const real = s1 - s2 * Math.cos(w);
  const imag = s2 * Math.sin(w);
  return real * real + imag * imag;
}

/** 12-bin chroma from a mono region (middle of track preferred). */
export function computeChroma(samples: Float32Array, sampleRate: number): number[] {
  const chroma = new Array(12).fill(0) as number[];
  // Use ~4s from the middle for stability.
  const winSec = Math.min(6, samples.length / sampleRate * 0.25);
  const win = Math.max(2048, Math.floor(winSec * sampleRate));
  const start = Math.max(0, Math.floor(samples.length * 0.4) - Math.floor(win / 2));
  const frame = samples.subarray(start, Math.min(samples.length, start + win));

  // Pitch classes across octaves 2–5
  for (let pc = 0; pc < 12; pc++) {
    let power = 0;
    for (let oct = 2; oct <= 5; oct++) {
      const freq = 440 * Math.pow(2, (pc - 9) / 12 + (oct - 4)); // A4=440 → pc 9
      if (freq < 60 || freq > sampleRate * 0.45) continue;
      power += goertzelPower(frame, sampleRate, freq);
    }
    chroma[pc] = power;
  }
  const sum = chroma.reduce((a, b) => a + b, 0) || 1;
  return chroma.map((v) => v / sum);
}

export function estimateCamelotKey(chroma: number[]): KeyEstimate {
  if (chroma.length !== 12 || !chroma.some((v) => v > 0 && Number.isFinite(v))) {
    return { camelot: null, confidence: 0 };
  }
  const candidates: { score: number; key: string }[] = [];
  for (let root = 0; root < 12; root++) {
    let major = 0;
    let minor = 0;
    for (let i = 0; i < 12; i++) {
      const idx = (i - root + 12) % 12;
      major += chroma[i]! * MAJOR_PROFILE[idx]!;
      minor += chroma[i]! * MINOR_PROFILE[idx]!;
    }
    candidates.push({ score: major, key: MAJOR_CAMELOT[root]! });
    candidates.push({ score: minor, key: MINOR_CAMELOT[root]! });
  }
  candidates.sort((a, b) => b.score - a.score);
  const first = candidates[0]!;
  const second = candidates[1]?.score ?? 0;
  const confidence = Math.min(
    1,
    Math.max(0.2, ((first.score - second) / Math.max(Math.abs(first.score), 1e-6)) * 5)
  );
  return { camelot: first.key, confidence };
}

type Parsed = { number: number; letter: "A" | "B" };

function parseCamelot(raw: string | null | undefined): Parsed | null {
  if (!raw) return null;
  const m = /^(\d{1,2})\s*([ABab])$/.exec(raw.trim());
  if (!m) return null;
  const number = Number(m[1]);
  if (number < 1 || number > 12) return null;
  return { number, letter: m[2]!.toUpperCase() as "A" | "B" };
}

function pitchClass(number: number, letter: "A" | "B"): number {
  if (letter === "A") {
    const minorMap: Record<number, number> = {
      1: 8, 2: 3, 3: 10, 4: 5, 5: 0, 6: 7, 7: 2, 8: 9, 9: 4, 10: 11, 11: 6, 12: 1,
    };
    return minorMap[number] ?? 0;
  }
  const majorMap: Record<number, number> = {
    1: 3, 2: 10, 3: 5, 4: 0, 5: 7, 6: 2, 7: 9, 8: 4, 9: 11, 10: 6, 11: 1, 12: 8,
  };
  return majorMap[number] ?? 0;
}

export function camelotCompatible(a: string | null, b: string | null): boolean {
  const pa = parseCamelot(a);
  const pb = parseCamelot(b);
  if (!pa || !pb) return false;
  if (pa.number === pb.number && pa.letter === pb.letter) return true;
  if (pa.number === pb.number && pa.letter !== pb.letter) return true; // relative
  if (pa.letter === pb.letter) {
    const d = Math.abs(pa.number - pb.number);
    return d === 1 || d === 11;
  }
  return false;
}

export function camelotMatch(keyA: string | null, keyB: string | null): HarmonicMatch {
  const a = parseCamelot(keyA);
  const b = parseCamelot(keyB);
  if (!a || !b || !keyA || !keyB) {
    return {
      isNaturallyCompatible: false,
      pitchShiftCents: 0,
      isHarmonicallyViable: true,
      description: "Тональность не определена",
    };
  }
  if (camelotCompatible(keyA, keyB)) {
    const label =
      a.number === b.number && a.letter === b.letter
        ? `Точное совпадение ключа (${keyA})`
        : a.number === b.number
          ? `Относительный мажор/минор (${keyA} ↔ ${keyB})`
          : `Смежный ключ (${keyA} → ${keyB})`;
    return {
      isNaturallyCompatible: true,
      pitchShiftCents: 0,
      isHarmonicallyViable: true,
      description: label,
    };
  }

  const pcA = pitchClass(a.number, a.letter);
  const targetPcB = a.letter === b.letter ? pcA : a.letter === "A" ? (pcA + 3) % 12 : (pcA + 9) % 12;
  const pcB = pitchClass(b.number, b.letter);
  let semitones = (targetPcB - pcB) % 12;
  if (semitones > 6) semitones -= 12;
  if (semitones < -6) semitones += 12;

  if (Math.abs(semitones) <= 2) {
    const cents = semitones * 100;
    const sign = cents > 0 ? `+${cents}` : `${cents}`;
    return {
      isNaturallyCompatible: false,
      pitchShiftCents: cents,
      isHarmonicallyViable: true,
      description: `Гармоническая подстройка: ${sign}¢ (${keyA} ↔ ${keyB})`,
    };
  }

  return {
    isNaturallyCompatible: false,
    pitchShiftCents: 0,
    isHarmonicallyViable: false,
    description: `Тональный конфликт (${keyA} vs ${keyB}, ${Math.abs(semitones)} п/т)`,
  };
}
