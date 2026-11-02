/**
 * Timed transcript → Automix cue hints.
 * Prefers phrase endings / vocal gaps so the mashup starts when words stop.
 *
 * LRC: use line (segment) boundaries — synthetic word gaps inside a line are
 * not real breaths. Whisper: word gaps + segment ends.
 */

export type TranscriptWord = {
  text: string;
  start: number;
  end: number;
};

export type TranscriptSegment = {
  text: string;
  start: number;
  end: number;
  words?: TranscriptWord[];
};

export type TrackTranscript = {
  language: string | null;
  source: "whisper" | "yandex-lrc" | "none";
  segments: TranscriptSegment[];
  /** Full plain text. */
  text: string;
};

export type CueFromTranscript = {
  mixOutSec: number | null;
  mixInSec: number | null;
  reason: string;
  /** Words near the automix cue (for UI). */
  cueWords: TranscriptWord[];
  confidence: number;
};

function allWords(t: TrackTranscript): TranscriptWord[] {
  const out: TranscriptWord[] = [];
  for (const s of t.segments) {
    if (s.words?.length) out.push(...s.words);
    else if (s.text.trim()) {
      out.push({ text: s.text.trim(), start: s.start, end: s.end });
    }
  }
  return out.sort((a, b) => a.start - b.start);
}

/** Shared Automix outro window — keep neural + planner aligned. */
export function outroWindow(
  durationSec: number,
  minTailSec = 24
): { earliest: number; latest: number } {
  const latest = Math.max(durationSec * 0.7, durationSec - minTailSec);
  const earliest = Math.min(latest, durationSec * 0.58);
  return { earliest, latest };
}

/**
 * Find the best mix-out: last solid vocal phrase end that still leaves `minTailSec`
 * of audio for the mashup window.
 */
export function cueFromTranscript(
  transcript: TrackTranscript,
  durationSec: number,
  minTailSec = 24
): CueFromTranscript {
  const words = allWords(transcript);
  const segs = transcript.segments
    .filter((s) => s.text.trim())
    .slice()
    .sort((a, b) => a.start - b.start);
  if ((!words.length && !segs.length) || durationSec < 40) {
    return {
      mixOutSec: null,
      mixInSec: null,
      reason: "no transcript words",
      cueWords: [],
      confidence: 0,
    };
  }

  const { earliest, latest } = outroWindow(durationSec, minTailSec);
  const isLrc = transcript.source === "yandex-lrc";
  const label = isLrc ? "LRC" : transcript.source === "whisper" ? "Whisper" : "Текст";

  let best: { at: number; score: number; idx: number; kind: string } | null = null;

  // 1) Segment / line ends — real phrase boundaries (especially LRC).
  for (let i = 0; i < segs.length; i++) {
    const s = segs[i]!;
    const next = segs[i + 1];
    if (s.end < earliest || s.end > latest) continue;
    const gap = next ? Math.max(0, next.start - s.end) : 2.5;
    // LRC: even a small inter-line pause is a phrase end; Whisper needs a breath.
    const minGap = isLrc ? 0.15 : 0.55;
    if (next && gap < minGap) continue;
    const room = (latest - s.end) / Math.max(1, minTailSec);
    const score =
      Math.min(4, Math.max(gap, isLrc ? 1.1 : gap)) * 2.2 +
      Math.min(1.5, room) +
      (isLrc ? 0.8 : 0);
    if (!best || score > best.score) {
      best = { at: s.end, score, idx: i, kind: "line" };
    }
  }

  // 2) Whisper word gaps ≥ 0.9s — instrumental / breath inside a long line.
  if (!isLrc) {
    for (let i = 0; i < words.length - 1; i++) {
      const a = words[i]!;
      const b = words[i + 1]!;
      if (a.end < earliest || a.end > latest) continue;
      const gap = b.start - a.end;
      if (gap < 0.9) continue;
      const room = (latest - a.end) / Math.max(1, minTailSec);
      const score = Math.min(4, gap) * 2 + Math.min(1.5, room);
      if (!best || score > best.score) {
        best = { at: a.end, score, idx: i, kind: "gap" };
      }
    }
  }

  // Fallback: end of last segment/word still before latest.
  if (!best) {
    for (let i = segs.length - 1; i >= 0; i--) {
      const s = segs[i]!;
      if (s.end >= earliest && s.end <= latest) {
        best = { at: s.end, score: 1, idx: i, kind: "last-line" };
        break;
      }
    }
  }
  if (!best) {
    for (let i = words.length - 1; i >= 0; i--) {
      const w = words[i]!;
      if (w.end >= earliest && w.end <= latest) {
        best = { at: w.end, score: 1, idx: i, kind: "last-word" };
        break;
      }
    }
  }

  // Mix-in: first sustained phrase after quiet intro (segment start preferred).
  let mixIn: number | null = null;
  const introLimit = Math.min(48, durationSec * 0.3);
  for (let i = 0; i < segs.length; i++) {
    const s = segs[i]!;
    if (s.start > introLimit) break;
    if (s.start < 3.5) continue;
    const prev = segs[i - 1];
    const gap = prev ? s.start - prev.end : s.start;
    // Enter after a quiet head / breath into a real line.
    if (gap >= 0.45 || s.start >= 6) {
      mixIn = Math.max(0, s.start - 0.12);
      break;
    }
  }
  if (mixIn == null) {
    for (let i = 0; i < words.length; i++) {
      const w = words[i]!;
      if (w.start > introLimit) break;
      const next = words[i + 1];
      if (w.start >= 4 && next && next.start - w.end < 0.8) {
        mixIn = Math.max(0, w.start - 0.15);
        break;
      }
    }
  }

  if (!best) {
    return {
      mixOutSec: null,
      mixInSec: mixIn,
      reason: "transcript has no usable outro phrase",
      cueWords: words.slice(-6),
      confidence: mixIn != null ? 0.35 : 0,
    };
  }

  const cueWords =
    best.kind === "line" || best.kind === "last-line"
      ? (segs[best.idx]?.words || words.filter(
          (w) => w.end >= best!.at - 6 && w.start <= best!.at + 0.5
        )).slice(-6)
      : words.slice(Math.max(0, best.idx - 4), best.idx + 1);

  const confidence =
    best.score >= 4 ? 0.9 : best.score >= 2.5 ? 0.78 : best.kind.startsWith("last") ? 0.55 : 0.68;

  return {
    mixOutSec: best.at,
    mixInSec: mixIn,
    reason: `${label} phrase end @${best.at.toFixed(1)}s (${best.kind})`,
    cueWords,
    confidence,
  };
}

/** Merge energy mixOut with transcript cue (prefer transcript when confident). */
export function blendMixOut(
  energyMixOut: number,
  transcriptCue: number | null,
  durationSec: number,
  minTailSec = 24,
  transcriptConfidence = 0.7
): { mixOut: number; usedTranscript: boolean } {
  const { earliest, latest } = outroWindow(durationSec, minTailSec);
  const clamp = (x: number) => Math.min(latest, Math.max(earliest, x));
  if (transcriptCue == null || !Number.isFinite(transcriptCue)) {
    return { mixOut: clamp(energyMixOut), usedTranscript: false };
  }
  const inWindow = transcriptCue >= earliest && transcriptCue <= latest;
  const delta = Math.abs(transcriptCue - energyMixOut);
  // High-confidence lyrics (LRC line end / Whisper breath) win inside the window.
  if (inWindow && transcriptConfidence >= 0.72) {
    const w = Math.min(0.85, 0.55 + transcriptConfidence * 0.35);
    return {
      mixOut: clamp(energyMixOut * (1 - w) + transcriptCue * w),
      usedTranscript: true,
    };
  }
  if (delta <= 12 || inWindow) {
    const mixOut = clamp(energyMixOut * 0.35 + transcriptCue * 0.65);
    return { mixOut, usedTranscript: true };
  }
  return { mixOut: clamp(energyMixOut), usedTranscript: false };
}

export function wordsAroundTime(
  transcript: TrackTranscript | null,
  timeSec: number,
  radius = 4
): TranscriptWord[] {
  if (!transcript) return [];
  const words = allWords(transcript);
  const near = words.filter(
    (w) => w.end >= timeSec - radius && w.start <= timeSec + radius
  );
  // Phrase-end cues often sit a few seconds after the last word (line end /
  // breath). Pull the whole line that ends near the cue so karaoke isn't empty.
  if (near.length >= 2) return near;
  for (const s of transcript.segments) {
    if (Math.abs(s.end - timeSec) <= radius + 0.5 && s.words?.length) {
      return s.words.slice(-6);
    }
  }
  return near;
}
