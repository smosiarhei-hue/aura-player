import type { MixSettings, Track, TrackAnalysis, WaveReason } from "../types";

/** Расстояние по темпу с учётом half/double-time */
export function bpmDistance(a: number, b: number): number {
  const r = Math.log2(a / b);
  const candidates = [Math.abs(r), Math.abs(r - 1), Math.abs(r + 1)];
  return Math.min(...candidates) * 12; // ~1 = 6% разницы
}

// Camelot wheel scoring based on Spotify-AutoMix & DJ best practices
function camelotParse(c: string): { n: number; letter: "A" | "B" } | null {
  if (!c) return null;
  const trimmed = c.trim().toUpperCase();
  const letter = trimmed.endsWith("A") ? "A" : trimmed.endsWith("B") ? "B" : null;
  if (!letter) return null;
  const n = parseInt(trimmed.slice(0, -1), 10);
  if (isNaN(n) || n < 1 || n > 12) return null;
  return { n, letter };
}

/** Оценка гармонической совместимости (0-100) по алгоритму Spotify-AutoMix */
export function keyHarmonicScore(c1: string | null | undefined, c2: string | null | undefined): number {
  if (!c1 || !c2) return 50;
  const p1 = camelotParse(c1);
  const p2 = camelotParse(c2);
  if (!p1 || !p2) return 50;

  const diff = (p2.n - p1.n + 12) % 12; // 0..11 на колесе

  if (p1.letter === p2.letter) {
    if (diff === 0) return 100; // Та же тональность (8A -> 8A)
    if (diff === 1 || diff === 11) return 90; // Соседняя (+/- 1)
    if (diff === 2) return 70; // Energy Boost (+2)
    return 20; // Несовместимо
  }
  // Переход между мажором и минором (A <-> B)
  if (diff === 0) return 85; // Относительная тональность (8A <-> 8B)
  if (diff === 1 || diff === 11) return 55; // Диагональное сведение
  return 20;
}

/** Совместимость по темпу (0-100) с учетом half/double-time (Spotify-AutoMix) */
export function bpmHarmonicScore(b1: number, b2: number): number {
  if (!b1 || !b2 || b1 <= 0 || b2 <= 0) return 50;
  const BPM_PERFECT = 0.02; // разница <= 2% -> 100 баллов
  const BPM_LIMIT = 0.08;   // разница >= 8% -> 0 баллов
  const HALF_DOUBLE_CAP = 85;

  let best = 0;
  for (const [mult, cap] of [[1.0, 100], [0.5, HALF_DOUBLE_CAP], [2.0, HALF_DOUBLE_CAP]] as const) {
    const diff = Math.abs(b2 * mult - b1) / b1;
    let score = 0;
    if (diff <= BPM_PERFECT) {
      score = 100;
    } else if (diff >= BPM_LIMIT) {
      score = 0;
    } else {
      score = 100 * (BPM_LIMIT - diff) / (BPM_LIMIT - BPM_PERFECT);
    }
    best = Math.max(best, Math.min(score, cap));
  }
  return best;
}

/** Сходство вайба / энергетики (0-100) */
export function vibeHarmonicScore(a: TrackAnalysis, b: TrackAnalysis): number {
  const dEnergy = Math.abs(a.energy - b.energy);
  const dDance = Math.abs(a.danceability - b.danceability);
  const dBright = Math.abs(a.brightness - b.brightness);
  const meanDiff = (dEnergy + dDance + dBright) / 3;
  return Math.max(0, Math.min(100, 100 * (1.0 - meanDiff / 0.55)));
}

/** Итоговый Flow Score (0-100) из Spotify-AutoMix: 45% Key, 35% BPM, 20% Vibe */
export function flowScore(a: TrackAnalysis, b: TrackAnalysis, settings?: MixSettings): number {
  const ks = keyHarmonicScore(a.camelot, b.camelot);
  const bs = bpmHarmonicScore(a.bpm, b.bpm);
  const vs = vibeHarmonicScore(a, b);

  const kw = settings?.keyMatch ?? true ? 0.45 : 0.15;
  const bw = settings?.beatmatch ?? true ? 0.35 : 0.15;
  const vw = 0.20;
  const totalW = kw + bw + vw;

  return Math.round((kw * ks + bw * bs + vw * vs) / totalW);
}

export function similarity(a: TrackAnalysis, b: TrackAnalysis, settings: MixSettings): number {
  // Для алгоритмов сортировки возвращаем расстояние (меньше = лучше)
  const score = flowScore(a, b, settings);
  const genreBonus = a.genre === b.genre ? 0 : 8;
  return (100 - score) + genreBonus;
}

export function reasons(a: TrackAnalysis, b: TrackAnalysis): WaveReason[] {
  const kScore = keyHarmonicScore(a.camelot, b.camelot);
  const bScore = bpmHarmonicScore(a.bpm, b.bpm);
  const flow = flowScore(a, b);
  const half = Math.abs(a.bpm * 2 - b.bpm) < 6 || Math.abs(a.bpm / 2 - b.bpm) < 6;

  return [
    {
      label: `Flow ${flow}%`,
      ok: flow >= 75,
    },
    {
      label: half ? `${a.bpm}→${b.bpm} (half-time)` : `${a.bpm}→${b.bpm} BPM`,
      ok: bScore >= 70,
    },
    {
      label: `${a.camelot} → ${b.camelot}`,
      ok: kScore >= 70,
    },
    {
      label: `энергия ${Math.round(a.energy * 100)}→${Math.round(b.energy * 100)}%`,
      ok: Math.abs(a.energy - b.energy) < 0.25,
    },
  ];
}

/**
 * Выбор следующего трека для «Моей волны».
 * Берём топ-3 по похожести и слегка рандомизируем — чтобы волна не была предсказуемой,
 * но при этом переходы оставались гладкими.
 */
export function pickNext(current: Track, pool: Track[], history: string[], settings: MixSettings): Track | null {
  const cur = current.analysis;
  const ready = pool.filter((t) => t.id !== current.id && t.analysis && t.buffer);
  if (!cur || ready.length === 0) return null;

  const recent = new Set(history.slice(-Math.min(history.length, Math.max(1, ready.length - 1))));
  let candidates = ready.filter((t) => !recent.has(t.id));
  if (candidates.length === 0) candidates = ready;

  const scored = candidates
    .map((t) => ({ t, s: similarity(cur, t.analysis!, settings) }))
    .sort((a, b) => a.s - b.s);
  const top = scored.slice(0, 3);
  const weights = top.map((x, i) => Math.exp(-x.s / 4) * (i === 0 ? 1.5 : 1));
  const sum = weights.reduce((a, b) => a + b, 0);
  let r = Math.random() * sum;
  for (let i = 0; i < top.length; i++) {
    r -= weights[i];
    if (r <= 0) return top[i].t;
  }
  return top[0].t;
}
