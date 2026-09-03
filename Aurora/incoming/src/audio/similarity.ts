import type { MixSettings, Track, TrackAnalysis, WaveReason } from "../types";

/** Расстояние по темпу с учётом half/double-time */
export function bpmDistance(a: number, b: number): number {
  const r = Math.log2(a / b);
  const candidates = [Math.abs(r), Math.abs(r - 1), Math.abs(r + 1)];
  return Math.min(...candidates) * 12; // ~1 = 6% разницы
}

function camelotParse(c: string) {
  const n = parseInt(c, 10);
  const letter = c.endsWith("A") ? "A" : "B";
  return { n, letter };
}

/** 0 — идеально, 1 — соседний, 2 — относительная тональность, >=3 — конфликт */
export function camelotDistance(a: string, b: string): number {
  const x = camelotParse(a), y = camelotParse(b);
  const wheel = Math.min((x.n - y.n + 12) % 12, (y.n - x.n + 12) % 12);
  if (x.letter === y.letter) return wheel === 0 ? 0 : wheel === 1 ? 1 : wheel + 1;
  return wheel === 0 ? 2 : wheel + 2;
}

export function similarity(a: TrackAnalysis, b: TrackAnalysis, settings: MixSettings): number {
  const dBpm = bpmDistance(a.bpm, b.bpm); // 0..~12
  const dKey = camelotDistance(a.camelot, b.camelot); // 0..8
  const dEnergy = Math.abs(a.energy - b.energy) * 10;
  const dBright = Math.abs(a.brightness - b.brightness) * 8;
  const dDance = Math.abs(a.danceability - b.danceability) * 5;
  const genrePenalty = a.genre === b.genre ? 0 : 3;
  return (
    dBpm * (settings.beatmatch ? 1.6 : 1.0) +
    dKey * (settings.keyMatch ? 1.2 : 0.3) +
    dEnergy +
    dBright +
    dDance +
    genrePenalty
  );
}

export function reasons(a: TrackAnalysis, b: TrackAnalysis): WaveReason[] {
  const dBpm = Math.abs(a.bpm - b.bpm);
  const half = Math.abs(a.bpm * 2 - b.bpm) < 4 || Math.abs(a.bpm / 2 - b.bpm) < 4;
  const dKey = camelotDistance(a.camelot, b.camelot);
  return [
    {
      label: half ? `${a.bpm}→${b.bpm} BPM (half-time)` : `${a.bpm}→${b.bpm} BPM`,
      ok: dBpm <= 8 || half,
    },
    { label: `${a.camelot} → ${b.camelot}`, ok: dKey <= 2 },
    { label: b.genre, ok: a.genre === b.genre },
    {
      label: `энергия ${Math.round(a.energy * 100)}→${Math.round(b.energy * 100)}`,
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
