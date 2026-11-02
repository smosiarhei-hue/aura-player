/**
 * Neural-ish Automix cue picker.
 * Fuses energy/vocal curves + timed lyrics into a bar-snapped mixOut / mixIn
 * while the track is already playing.
 */
import type { TrackAIProfile } from "./analyzeTrack";
import {
  blendMixOut,
  cueFromTranscript,
  outroWindow,
  type TrackTranscript,
} from "./transcriptCues";

export type NeuralCue = {
  mixOutSec: number;
  mixInSec: number;
  confidence: number;
  reason: string;
  source: "energy" | "lyrics" | "fused";
};

export type NeuralCueRole = "outgoing" | "incoming" | "both";

function snapToBar(sec: number, bpm: number): number {
  const bar = (60 / Math.max(60, Math.min(200, bpm || 120))) * 4;
  if (!(bar > 0.4)) return sec;
  return Math.max(0, Math.round(sec / bar) * bar);
}

function clampOut(sec: number, duration: number, minTail = 24): number {
  const { earliest, latest } = outroWindow(duration, minTail);
  return Math.min(latest, Math.max(earliest, sec));
}

/**
 * Score a candidate mix-out: vocal drop + energy bed + transcript phrase end.
 */
export function neuralPickMixOut(
  profile: TrackAIProfile,
  transcript: TrackTranscript | null
): NeuralCue {
  const duration = profile.durationSec;
  const energyCue = profile.mixOutSec;
  const tx = transcript ? cueFromTranscript(transcript, duration, 24) : null;
  const blended = blendMixOut(
    energyCue,
    tx?.mixOutSec ?? null,
    duration,
    24,
    tx?.confidence ?? 0.7
  );

  let mixOut = blended.mixOut;
  let source: NeuralCue["source"] = blended.usedTranscript ? "fused" : "energy";
  let confidence = blended.usedTranscript
    ? Math.max(0.72, tx?.confidence ?? 0.78)
    : 0.55;

  // Local vocal/energy refinement around the candidate (±8s).
  // When lyrics are high-confidence, stay close to the phrase end.
  const hop = 0.25;
  const energy = profile.energy;
  const vocal = profile.vocalPresence;
  const lyricsLock = blended.usedTranscript && (tx?.confidence ?? 0) >= 0.75;
  if (energy.length > 16 && vocal.length === energy.length) {
    const center = Math.floor(mixOut / hop);
    const radius = lyricsLock ? 16 : 32;
    const lo = Math.max(0, center - radius);
    const hi = Math.min(energy.length - 2, center + (lyricsLock ? 24 : 48));
    let best = center;
    let bestScore = -1;
    for (let i = lo; i < hi; i++) {
      const v0 = vocal[i] ?? 0;
      const v1 = vocal[Math.min(vocal.length - 1, i + 4)] ?? 0;
      const e0 = energy[i] ?? 0;
      const drop = Math.max(0, v0 - v1);
      const bed = e0 * (1 - v1);
      let ahead = 0;
      for (let k = 0; k < 24; k++) ahead += energy[Math.min(energy.length - 1, i + k)] ?? 0;
      ahead /= 24;
      let localMax = e0;
      for (let k = -12; k <= 24; k++) {
        const idx = Math.max(0, Math.min(energy.length - 1, i + k));
        localMax = Math.max(localMax, energy[idx] ?? 0);
      }
      // A breakdown 6–10 dB under the surrounding phrase is a hole, not a bed.
      const hole = ahead < Math.max(0.32, localMax * 0.58) ? 4.5 : 0;
      const nearTx =
        tx?.mixOutSec != null
          ? 1 - Math.min(1, Math.abs(i * hop - tx.mixOutSec) / (lyricsLock ? 4 : 8))
          : 0.4;
      const txWeight = lyricsLock ? 2.4 : 1.4;
      const score = drop * 2.2 + bed * 1.1 + ahead * 1.8 + nearTx * txWeight - hole;
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (bestScore > 0.35) {
      mixOut = best * hop;
      confidence = Math.min(0.95, Math.max(confidence, 0.5 + bestScore / 6));
      if (blended.usedTranscript) source = "fused";
    }
  } else if (blended.usedTranscript) {
    source = "lyrics";
    confidence = Math.max(confidence, 0.82);
  }

  mixOut = snapToBar(clampOut(mixOut, duration), profile.bpm || 120);
  mixOut = clampOut(mixOut, duration);

  const mixIn =
    tx?.mixInSec != null && Number.isFinite(tx.mixInSec)
      ? Math.max(0, Math.min(duration * 0.28, tx.mixInSec))
      : profile.mixInSec;

  const reason = [
    source === "lyrics"
      ? "LRC/Whisper phrase"
      : source === "fused"
        ? "energy×lyrics"
        : "energy/vocal",
    `@${mixOut.toFixed(1)}s`,
    `conf ${(confidence * 100) | 0}%`,
    tx?.reason && blended.usedTranscript ? tx.reason : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return { mixOutSec: mixOut, mixInSec: mixIn, confidence, reason, source };
}

/**
 * Apply neural cue onto a profile (immutable).
 * - outgoing: mixOut only (deck A exit)
 * - incoming: mixIn only (deck B entry)
 * - both: both (legacy / single-track refine)
 */
export function withNeuralCue(
  profile: TrackAIProfile,
  transcript: TrackTranscript | null,
  role: NeuralCueRole = "both"
): TrackAIProfile {
  const cue = neuralPickMixOut(profile, transcript);
  if (role === "outgoing") {
    return {
      ...profile,
      mixOutSec: cue.mixOutSec,
      reason: `${profile.reason} · neural out ${cue.reason}`,
    };
  }
  if (role === "incoming") {
    return {
      ...profile,
      mixInSec: cue.mixInSec,
      reason: `${profile.reason} · neural in @${cue.mixInSec.toFixed(1)}s`,
    };
  }
  return {
    ...profile,
    mixOutSec: cue.mixOutSec,
    mixInSec: cue.mixInSec,
    reason: `${profile.reason} · neural ${cue.reason}`,
  };
}

/** Instant profile so playback can start before deep analysis. */
export function provisionalProfile(
  durationSec: number,
  name: string
): TrackAIProfile {
  const dur = Math.max(30, durationSec);
  return {
    name,
    durationSec: dur,
    bpm: 120,
    bpmConfidence: 0.15,
    camelotKey: null,
    keyConfidence: 0,
    energy: [],
    vocalPresence: [],
    mixInSec: 0,
    mixOutSec: Math.max(dur * 0.72, dur - 32),
    hasFadeOut: false,
    endsInSilence: false,
    tempoStability: 0.4,
    reason: "provisional · Automix считает в фоне",
  };
}
