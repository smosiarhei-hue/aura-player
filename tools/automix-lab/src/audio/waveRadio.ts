/**
 * Continuous «Моя волна» radio with DJ mashup handoffs.
 *
 * PLAY current → near mixOut → LOCK…MASHUP…LAND → promote B → prefetch next → …
 * Dual mashup only when A outro is instrumental; else Safe Exit (phrase Automix).
 */
import { AutomixEngine, type AudioMeter, type EngineSnapshot } from "./engine";
import { wantsLeadKill } from "./envelopes";
import { analyzeTrackBuffer, type TrackAIProfile } from "./analyzeTrack";
import { planAutomix, recheckMix, vocalLevelNear, type AIMixPlan } from "./aiMixEngine";
import { planOneBarDuet } from "./oneBarDuet";
import { defaultParams } from "./envelopes";
import { premiumLandBlurb } from "./premiumAutomix";
import {
  applyCoachOffsets,
  bakedLeadKill,
  scoreTransition,
  type CoachOffsets,
  type CoachReport,
  type MeterPoint,
  DEFAULT_OFFSETS,
} from "./transitionCoach";
import {
  wordsAroundTime,
  type TrackTranscript,
  type TranscriptWord,
} from "./transcriptCues";
import {
  provisionalProfile,
  withNeuralCue,
} from "./neuralAutomix";

export type WaveTrackMeta = {
  id: string;
  title: string;
  artists: string;
  durationMs: number;
  coverUrl: string | null;
  url: string;
  fileName: string;
  codec?: string;
  bitrateKbps?: number;
  quality?: "lossless" | "hq" | "nq";
  /** 320 if Yandex offered it, otherwise 192. */
  qualityNote?: string;
};

export type WaveRadioState =
  | "idle"
  | "needAuth"
  | "loading"
  | "playing"
  | "mixing"
  | "error";

/** Song Transitions: AutoMix | Duet (4-bar dual vocal) | Crossfade | Off. */
export type TransitionMode = "automix" | "duet" | "crossfade" | "off";

const TRANSITION_KEY = "sonivo-song-transitions";

const CROSSFADE_KEY = "sonivo-song-transitions-sec";

function loadTransitionMode(): TransitionMode {
  try {
    const v = localStorage.getItem(TRANSITION_KEY);
    if (v === "automix" || v === "duet" || v === "crossfade" || v === "off") return v;
  } catch {
    /* SSR / private */
  }
  return "automix";
}

function loadCrossfadeSec(): number {
  try {
    const n = Number(localStorage.getItem(CROSSFADE_KEY));
    if (Number.isFinite(n)) return Math.min(12, Math.max(1, Math.round(n)));
  } catch {
    /* SSR / private */
  }
  return 8;
}

export type WaveRadioSnapshot = {
  state: WaveRadioState;
  status: string;
  current: WaveTrackMeta | null;
  next: WaveTrackMeta | null;
  phase: string;
  mixing: boolean;
  progress: number;
  elapsed: number;
  duration: number;
  planMode: string | null;
  /** Planned mashup/duet window length (content-aware). */
  blendSec: number | null;
  planStory: string | null;
  planBlurb: string;
  criticOk: boolean | null;
  quality: string | null;
  qualityNote: string | null;
  coachScore: number | null;
  coachStory: string | null;
  coachAvg: number | null;
  /** Seconds where Automix mashup starts (scrub limit). */
  automixAtSec: number | null;
  /** Max scrub position (Automix/Duet cue, or near end before plan). */
  scrubMaxSec: number;
  canSeek: boolean;
  transcript: TrackTranscript | null;
  transcriptStatus: string | null;
  /** Background Automix brain phase (runs while song plays). */
  brainStatus: string | null;
  /** HTDemucs window: download/separate while the song plays, then the mix uses it. */
  stemStatus: string | null;
  cueWords: TranscriptWord[];
  engine: EngineSnapshot | null;
  /** Apple-style Song Transitions mode. */
  transitionMode: TransitionMode;
  /** Fixed crossfade length when mode=crossfade (1…12). */
  crossfadeSec: number;
  /** Current track BPM for beat-synced UI. */
  bpm: number;
  /** Active DSP kills / guards for the planned or live mix (one strip in UI). */
  kills: string[];
};

type Listener = (s: WaveRadioSnapshot) => void;

type StemJobState = {
  phase: "queued" | "running" | "ready" | "error";
  startSec: number;
  durationSec: number;
  vocalsUrl?: string;
  instrumentalUrl?: string;
  beatUrl?: string;
};

async function fetchJson<T>(url: string, init?: RequestInit): Promise<T> {
  const r = await fetch(url, init);
  const body = (await r.json().catch(() => ({}))) as T & { error?: string };
  if (!r.ok) throw new Error(body.error || `${url} → ${r.status}`);
  return body;
}

export class WaveRadio {
  private engine = new AutomixEngine(defaultParams());
  private running = false;
  private state: WaveRadioState = "idle";
  private status = "Подключи Яндекс и жми Play";
  private current: WaveTrackMeta | null = null;
  private next: WaveTrackMeta | null = null;
  private profileA: TrackAIProfile | null = null;
  private profileB: TrackAIProfile | null = null;
  private plan: AIMixPlan | null = null;
  private lastEngine: EngineSnapshot | null = null;
  private listeners = new Set<Listener>();
  private loopGen = 0;
  private coach: CoachOffsets = { ...DEFAULT_OFFSETS };
  private lastCoachReport: CoachReport | null = null;
  private mashupTrail: MeterPoint[] = [];
  private loggingMashup = false;
  private transcriptA: TrackTranscript | null = null;
  private transcriptB: TrackTranscript | null = null;
  private transcriptStatus: string | null = null;
  private brainStatus: string | null = null;
  private stemStatus: string | null = null;
  private stemJobs = new Map<string, StemJobState>();
  private brainGen = 0;
  private pendingSeek: number | null = null;
  private scrubbing = false;
  private planReadyResolve: (() => void) | null = null;
  private cueWatchTimer: number | null = null;
  private transitionMode: TransitionMode = loadTransitionMode();
  private crossfadeSec = loadCrossfadeSec();

  constructor() {
    this.engine.onUpdate((snap) => {
      this.lastEngine = snap;
      if (this.loggingMashup && snap.playing) {
        this.mashupTrail.push({
          p: snap.progress,
          phase: snap.phase,
          volA: snap.volA,
          volB: snap.volB,
          instrA: snap.instrA,
          instrB: snap.instrB,
          bassA: snap.bassA,
          bassB: snap.bassB,
          hpfA: snap.hpfA,
          echoA: snap.echoA,
          reverbA: snap.reverbA,
          stutterA: snap.stutterA,
          rateB: snap.rateB,
          pitchB: snap.pitchB,
        });
        if (this.mashupTrail.length > 2000) this.mashupTrail.shift();
      }
      this.emit();
    });
    void this.refreshCoach();
  }

  private async refreshCoach() {
    try {
      this.coach = await fetchJson<CoachOffsets>("/api/mix/coach");
      this.emit();
    } catch {
      /* offline */
    }
  }

  onChange(cb: Listener) {
    this.listeners.add(cb);
    cb(this.snapshot());
    return () => this.listeners.delete(cb);
  }

  /**
   * Compact session dump for debugging how AutoMix actually ran.
   * Samples the live mashup trail (~48 points) plus the plan FX recipe.
   */
  sessionLog(): Record<string, unknown> {
    const p = this.plan?.params;
    const dsp = p?.dsp;
    const step = Math.max(1, Math.ceil(this.mashupTrail.length / 48));
    const trail = this.mashupTrail.filter((_, i) => i % step === 0).map((m) => ({
      p: Number(m.p.toFixed(3)),
      phase: m.phase,
      volA: Number(m.volA.toFixed(3)),
      volB: Number(m.volB.toFixed(3)),
      instrA: Number(m.instrA.toFixed(3)),
      instrB: Number(m.instrB.toFixed(3)),
      bassA: Number(m.bassA.toFixed(2)),
      bassB: Number(m.bassB.toFixed(2)),
      hpfA: Number((m.hpfA ?? 0).toFixed(3)),
      echoA: Number((m.echoA ?? 0).toFixed(3)),
      reverbA: Number((m.reverbA ?? 0).toFixed(3)),
      stutterA: Number((m.stutterA ?? 0).toFixed(3)),
      rateB: Number((m.rateB ?? 1).toFixed(3)),
      pitchB: Number((m.pitchB ?? 0).toFixed(1)),
    }));
    return {
      at: new Date().toISOString(),
      state: this.state,
      status: this.status,
      transitionMode: this.transitionMode,
      brain: this.brainStatus,
      pair: {
        a: this.current
          ? `${this.current.artists} — ${this.current.title}`
          : null,
        b: this.next ? `${this.next.artists} — ${this.next.title}` : null,
      },
      plan: p
        ? {
            story: this.plan?.story ?? null,
            archetype: p.archetype,
            mode: dsp?.mashupMode ?? null,
            blendSec: Number(p.blendDurationSec.toFixed(2)),
            cueASec: Number(p.cueASec.toFixed(2)),
            cueBSec: Number(p.cueBSec.toFixed(2)),
            bpm: p.targetBPM,
            rateA: p.rateA,
            rateB: p.rateB,
            pitchCentsB: p.pitchCentsB,
            handoffAt: Number(p.handoffAt.toFixed(3)),
            bassSwapAt: Number(p.bassSwapAt.toFixed(3)),
            loopBarsA: dsp?.loopBarsA ?? 0,
            echoAPeak: dsp?.echoAPeak ?? 0,
            reverbAPeak: dsp?.reverbAPeak ?? 0,
            stutterAPeak: dsp?.stutterAPeak ?? 0,
            hpfAPeak: dsp?.hpfAPeak ?? 0,
            decisions: dsp?.decisions ?? [],
            critic: this.plan?.critic
              ? {
                  ok: this.plan.critic.ok,
                  score: this.plan.critic.score,
                  mode: this.plan.critic.mode,
                  fixes: this.plan.critic.fixes,
                }
              : null,
          }
        : null,
      coach: this.lastCoachReport
        ? { score: this.lastCoachReport.score, story: this.lastCoachReport.story }
        : null,
      samples: this.mashupTrail.length,
      trail,
    };
  }

  /** Persist the session log on the lab server (`.automix-session.json`). */
  async saveSessionLog(): Promise<{ ok: boolean; path?: string; error?: string }> {
    const body = this.sessionLog();
    const r = await fetch("/api/mix/session", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = (await r.json().catch(() => ({}))) as {
      ok?: boolean;
      path?: string;
      error?: string;
    };
    if (!r.ok || !data.ok) {
      return { ok: false, error: data.error || `HTTP ${r.status}` };
    }
    return { ok: true, path: data.path };
  }

  snapshot(): WaveRadioSnapshot {
    return {
      state: this.state,
      status: this.status,
      current: this.current,
      next: this.next,
      phase: this.lastEngine?.phase ?? "",
      mixing: this.state === "mixing",
      progress: this.lastEngine?.progress ?? 0,
      elapsed:
        this.scrubbing && this.pendingSeek != null
          ? this.pendingSeek
          : (this.lastEngine?.displayElapsed ?? 0),
      duration: this.lastEngine?.displayDuration ?? 0,
      planMode: this.plan?.params.dsp.mashupMode ?? null,
      blendSec: this.plan?.params.blendDurationSec ?? null,
      planStory: this.plan?.story ?? null,
      planBlurb: premiumLandBlurb(this.plan),
      criticOk: this.plan?.critic?.ok ?? null,
      quality: this.current
        ? this.current.quality === "lossless"
          ? `FLAC${this.current.bitrateKbps ? ` · ${this.current.bitrateKbps}` : ""}`
          : this.current.quality === "hq"
            ? `HQ ${this.current.bitrateKbps || "?"} kbps`
            : this.current.bitrateKbps
              ? `${(this.current.codec || "mp3").toUpperCase()} ${this.current.bitrateKbps} kbps`
              : this.current.codec || null
        : null,
      qualityNote: this.current?.qualityNote ?? null,
      coachScore: this.lastCoachReport?.score ?? null,
      coachStory: this.lastCoachReport?.story ?? null,
      coachAvg: this.coach.samples > 0 ? this.coach.avgScore : null,
      automixAtSec: this.automixAt(),
      scrubMaxSec: this.scrubMax(),
      // Seek anytime during solo play — don't wait for Automix/Duet plan.
      canSeek: this.state === "playing" && !this.loggingMashup,
      // After LAND the display clock is B — don't paint A's LRC on B's timeline.
      transcript:
        this.state === "mixing" && this.lastEngine?.displayDeck === "b"
          ? null
          : this.transcriptA,
      transcriptStatus:
        this.state === "mixing" && this.lastEngine?.displayDeck === "b"
          ? "LAND · текст следующего после сведения"
          : this.transcriptStatus,
      brainStatus: this.brainStatus,
      stemStatus: this.stemStatus,
      cueWords: wordsAroundTime(
        this.state === "mixing" && this.lastEngine?.displayDeck === "b"
          ? null
          : this.transcriptA,
        this.lastEngine?.displayElapsed ?? this.automixAt() ?? 0,
        5
      ),
      engine: this.lastEngine,
      transitionMode: this.transitionMode,
      crossfadeSec: this.crossfadeSec,
      bpm:
        this.state === "mixing" && this.lastEngine?.displayDeck === "b"
          ? this.engine.getBpm("b")
          : this.profileA?.bpm || this.engine.getBpm("a"),
      kills: this.activeKills(),
    };
  }

  /** Compact kill chips: Lead / stems / Vocal Safe / Bass Surgeon / duck. */
  private activeKills(): string[] {
    const dsp = this.plan?.params.dsp;
    if (!dsp) return [];
    const kills: string[] = [];
    const dec = (dsp.decisions || []).join(" · ");
    if (dsp.mashupMode === "oneBarDuet" || dsp.bakeVocalA || (dsp.vocalAPeak || 0) >= 0.55) {
      kills.push("Vocal A");
    }
    if (wantsLeadKill(dsp) || /lead.?kill|acapella drop/i.test(dec)) kills.push("Lead kill");
    else if (dsp.bakeInstrA || (dsp.instrAPeak || 0) >= 0.35) kills.push("Instr A");
    if (dsp.bakeInstrB || (dsp.instrBPeak || 0) >= 0.35) kills.push("Instr B");
    if (dsp.bakeVocalB || (dsp.vocalBPeak || 0) >= 0.4) kills.push("Vocal B");
    if (dsp.mashupMode === "oneBarDuet") kills.push("Instr B only");
    if (/vocal safe/i.test(dec)) kills.push("Vocal Safe");
    if (/bass surgeon/i.test(dec)) kills.push("Bass Surgeon");
    if ((dsp.vocalDuckBDb || 0) <= -3) kills.push("Mid duck");
    if ((dsp.sidechainA || 0) >= 0.25 && dsp.mashupMode !== "oneBarDuet") kills.push("Sidechain");
    if (dsp.mashupMode === "oneBarDuet") {
      if ((dsp.echoAPeak || 0) >= 0.35) kills.push("Echo out");
      if ((dsp.hpfAPeak || 0) >= 0.4) kills.push("HPF A");
      if ((dsp.lpfBPeak || 0) >= 0.35) kills.push("LPF B");
    }
    // Cap so the strip stays one calm row.
    return kills.slice(0, 5);
  }

  /** Live spectrum for ambient pulse (bass/mid/treble/level). */
  getMeter(): AudioMeter {
    return this.engine.getMeter();
  }

  getTransitionMode(): TransitionMode {
    return this.transitionMode;
  }

  setOutputVolume(value: number) {
    this.engine.setOutputVolume(value);
  }

  setTransitionMode(mode: TransitionMode) {
    if (
      mode !== "automix" &&
      mode !== "duet" &&
      mode !== "crossfade" &&
      mode !== "off"
    ) {
      return;
    }
    this.transitionMode = mode;
    try {
      localStorage.setItem(TRANSITION_KEY, mode);
    } catch {
      /* ignore */
    }
    // Re-plan when switching into/out of Duet so cue + blend match the mode.
    if (this.profileA && this.profileB && this.state !== "mixing") {
      void this.planPair({ retarget: true }).catch(() => undefined);
    }
    this.retargetForMode();
    this.emit();
  }

  setCrossfadeSec(sec: number) {
    this.crossfadeSec = Math.min(12, Math.max(1, Math.round(sec)));
    try {
      localStorage.setItem(CROSSFADE_KEY, String(this.crossfadeSec));
    } catch {
      /* ignore */
    }
    if (this.transitionMode === "crossfade") this.retargetForMode();
    this.emit();
  }

  private automixAt(): number | null {
    const dur = this.profileA?.durationSec || this.engine.getDeck("a").duration || 0;
    if (this.transitionMode === "off") return dur > 1 ? Math.max(0, dur - 0.15) : null;
    if (this.transitionMode === "crossfade") {
      return dur > 1 ? Math.max(0, dur - this.crossfadeSec) : null;
    }
    if (this.plan) return this.plan.params.cueASec;
    if (this.profileA) return this.profileA.mixOutSec;
    return null;
  }

  /** Max scrub position: Automix/Duet cue if known, else near track end. */
  private scrubMax(): number {
    const metaDur = this.current?.durationMs ? this.current.durationMs / 1000 : 0;
    const dur =
      this.profileA?.durationSec || this.engine.getDeck("a").duration || metaDur || 0;
    const pos = this.engine.getSoloPosition();
    const at = this.automixAt();
    const cueCap =
      at != null && at > 1
        ? Math.max(0, at - 0.35)
        : dur > 2
          ? Math.max(0, Math.min(this.softUntilSec(), dur - 0.35))
          : Math.max(30, pos + 15);
    // If playback is already past the cue, keep the current spot reachable
    // so a rewind does not snap the song into the mix.
    return Math.max(cueCap, Math.min(Math.max(0, dur - 0.35), pos));
  }

  /**
   * Scrub current track during solo play (before mashup).
   * Works even while the Automix brain is still planning.
   */
  seekTo(sec: number) {
    if (this.state !== "playing" || this.loggingMashup) return;
    const max = this.scrubMax();
    const clamped = Math.max(0, Math.min(sec, max));
    this.pendingSeek = clamped;
    this.scrubbing = true;
    this.engine.interruptSolo();
    this.emit();
  }

  /** Where solo playback should hand off, given the current Song Transitions mode. */
  private softUntilSec(): number {
    const dur = this.profileA?.durationSec || this.engine.getDeck("a").duration || 180;
    if (this.transitionMode === "off") {
      if (this.profileA?.endsInSilence && this.profileA.mixOutSec > 1) {
        return Math.max(8, Math.min(dur - 0.15, this.profileA.mixOutSec));
      }
      return Math.max(1, dur - 0.15);
    }
    if (this.transitionMode === "crossfade") {
      return Math.max(1, dur - this.crossfadeSec);
    }
    return Math.max(40, dur - 6);
  }

  /** Move the live solo end when the listener changes mode mid-song. */
  private retargetForMode() {
    if (this.state === "mixing" || !this.engine.isSoloPlaying()) return;
    if (
      (this.transitionMode === "automix" || this.transitionMode === "duet") &&
      this.plan
    ) {
      this.retargetCueFromPlan();
      return;
    }
    this.engine.setSoloUntil(this.softUntilSec());
  }

  /** Solo playback; prefers live plan cueA when brain has finished. */
  private async playSeekableUntil(
    fromSec: number,
    softUntilSec: number,
    rate: number,
    gen: number
  ): Promise<"reached" | "stopped" | "aborted"> {
    let from = fromSec;
    while (this.running && gen === this.loopGen) {
      if (this.pendingSeek != null) {
        from = this.pendingSeek;
        this.pendingSeek = null;
        this.scrubbing = false;
      }
      const until =
        this.transitionMode === "automix" || this.transitionMode === "duet"
          ? (this.plan?.params.cueASec ?? softUntilSec)
          : softUntilSec;
      if (from >= until - 0.25) return "reached";
      const start = from;
      const reached = await this.engine.playSoloUntil("a", start, until, rate);
      if (!this.running || gen !== this.loopGen) return "aborted";
      if (this.pendingSeek != null || this.scrubbing) {
        from = this.pendingSeek ?? start;
        this.pendingSeek = null;
        this.scrubbing = false;
        continue;
      }
      return reached ? "reached" : "stopped";
    }
    return "aborted";
  }

  private resetPairState() {
    this.plan = null;
    this.next = null;
    this.profileB = null;
  }

  private beginPlanGate() {
    this.planReadyResolve = () => undefined;
  }

  private signalPlanReady() {
    this.planReadyResolve?.();
    this.planReadyResolve = null;
  }

  /** Hot-retarget Automix / Duet cue while the song is playing. */
  private retargetCueFromPlan() {
    if (!this.plan || this.state === "mixing") return;
    if (this.transitionMode !== "automix" && this.transitionMode !== "duet") {
      if (this.engine.isSoloPlaying()) this.engine.setSoloUntil(this.softUntilSec());
      this.brainStatus =
        this.transitionMode === "crossfade"
          ? `Crossfade · ${this.crossfadeSec}s`
          : "Off · до конца трека";
      this.emit();
      return;
    }
    const cue = this.plan.params.cueASec;
    const pos = this.engine.isSoloPlaying()
      ? this.engine.getSoloPosition()
      : 0;
    // Need ≥3.2s lead to bake stems. If Whisper landed behind the playhead,
    // jump to the next safe exit instead of mashing mid-line.
    let target = cue;
    if (cue < pos + 3.2) {
      const dur =
        this.profileA?.durationSec || this.engine.getDeck("a").duration || cue + 24;
      const nextSafe = Math.min(dur - 4, Math.max(pos + 4.5, pos + 0.5));
      target = nextSafe;
      // Keep the live plan in sync — otherwise the loop rewinds to a stale cueA
      // and playAutoMashup stop()+bake kills audio right after the new song lands.
      this.plan.params.cueASec = target;
      this.brainStatus = `Automix · late cue → exit @ ${target.toFixed(1)}s`;
    } else {
      target = cue;
      this.brainStatus = `Automix · cue @ ${cue.toFixed(1)}s · Whisper ready`;
    }
    this.engine.setSoloUntil(target);
    this.emit();
  }

  private stopCueWatch() {
    if (this.cueWatchTimer != null) {
      window.clearInterval(this.cueWatchTimer);
      this.cueWatchTimer = null;
    }
  }

  /** Re-score neural cue every few seconds while A plays (ASR may finish late). */
  private startCueWatch(gen: number) {
    this.stopCueWatch();
    this.cueWatchTimer = window.setInterval(() => {
      if (gen !== this.loopGen || this.state !== "playing") return;
      if (!this.profileA || !this.profileB || !this.transcriptA) return;
      if (this.loggingMashup) return;
      const next = withNeuralCue(this.profileA, this.transcriptA, "outgoing");
      const delta = Math.abs(next.mixOutSec - this.profileA.mixOutSec);
      if (delta < 1.25) return;
      this.profileA = next;
      void this.planPair({ retarget: true }).catch(() => undefined);
    }, 4000);
  }

  private emit() {
    const s = this.snapshot();
    for (const cb of this.listeners) cb(s);
  }

  private setStatus(state: WaveRadioState, status: string) {
    this.state = state;
    this.status = status;
    this.emit();
  }

  async checkAuth(): Promise<boolean> {
    const s = await fetchJson<{ connected: boolean; login: string | null }>(
      "/api/ym/status"
    );
    if (!s.connected) {
      this.setStatus("needAuth", "Нужен Яндекс — Device Flow ниже");
      return false;
    }
    // Never clobber an active Automix session back to idle.
    if (
      this.running ||
      this.state === "playing" ||
      this.state === "mixing" ||
      this.state === "loading"
    ) {
      return true;
    }
    this.setStatus("idle", `Sonivo · ${s.login || "ok"} · жми Play`);
    return true;
  }

  private async fetchNextTrack(): Promise<WaveTrackMeta> {
    const body = await fetchJson<{ track: WaveTrackMeta }>("/api/ym/wave/next", {
      method: "POST",
    });
    return body.track;
  }

  /** Download + decode only — critical path to first audio. */
  private async decodeDeck(
    id: "a" | "b",
    meta: WaveTrackMeta,
    quiet = false
  ): Promise<void> {
    if (!quiet) {
      this.setStatus("loading", `Открываю файл · ${meta.artists} — ${meta.title}`);
    }
    const r = await fetch(meta.url);
    if (!r.ok) throw new Error(`Не скачался ${meta.title}`);
    const buf = await r.arrayBuffer();
    if (!quiet) this.setStatus("loading", `Декодирую · ${meta.title}`);
    await this.engine.loadArrayBuffer(id, buf, meta.fileName);
    if (!this.engine.getDeck(id).buffer) throw new Error("decode failed");
    this.queueStemWindow(id, meta);
  }

  /**
   * HTDemucs on the transition window only, in parallel with playback.
   * Repo: https://github.com/StemSplit/demucs-onnx — Yandex has no stem API.
   * Outro is the last 36s, intro the first 36s. The mashup plays them when both are ready.
   */
  private queueStemWindow(id: "a" | "b", meta: WaveTrackMeta) {
    const file = decodeURIComponent(meta.url.split("/").pop() || "");
    if (!file) return;
    const dur = Math.max(1, meta.durationMs / 1000 || this.engine.getDeck(id).duration || 1);
    const role = id === "a" ? "outro" : "intro";
    const durationSec = Math.min(36, dur);
    const startSec = role === "outro" ? Math.max(0, dur - durationSec) : 0;
    this.enqueueStem(meta, role, file, startSec, durationSec);
  }

  /** Separate [start, start+duration] when the default outro/intro misses the plan cue. */
  private alignStemToPlan() {
    if (!this.plan) return;
    const need = Math.min(36, Math.max(12, this.plan.params.blendDurationSec + 8));
    if (this.current) {
      const file = decodeURIComponent(this.current.url.split("/").pop() || "");
      const dur = Math.max(1, this.current.durationMs / 1000 || this.engine.getDeck("a").duration || 1);
      const start = Math.max(0, Math.min(this.plan.params.cueASec, Math.max(0, dur - need)));
      if (file) this.enqueueStem(this.current, "outro", file, start, Math.min(need, dur));
    }
    if (this.next) {
      const file = decodeURIComponent(this.next.url.split("/").pop() || "");
      const dur = Math.max(1, this.next.durationMs / 1000 || this.engine.getDeck("b").duration || 1);
      const start = Math.max(0, Math.min(this.plan.params.cueBSec, Math.max(0, dur - need)));
      if (file) this.enqueueStem(this.next, "intro", file, start, Math.min(need, dur));
    }
  }

  private enqueueStem(
    meta: WaveTrackMeta,
    role: "outro" | "intro",
    file: string,
    startSec: number,
    durationSec: number
  ) {
    const key = `${role}:${meta.id}:${Math.round(startSec)}`;
    const existing = this.stemJobs.get(key);
    if (existing && existing.phase !== "error") return;
    const job: StemJobState = { phase: "queued", startSec, durationSec };
    this.stemJobs.set(key, job);
    this.refreshStemStatus();
    void fetch("/api/stems/window", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        file,
        trackId: meta.id,
        startSec,
        durationSec,
        role,
      }),
    })
      .then(async (r) => {
        if (!r.ok) {
          job.phase = "error";
          this.refreshStemStatus();
          return;
        }
        const posted = (await r.json()) as StemJobState;
        if (posted.phase === "ready" && posted.vocalsUrl && posted.instrumentalUrl) {
          job.phase = "ready";
          job.vocalsUrl = posted.vocalsUrl;
          job.instrumentalUrl = posted.instrumentalUrl;
          job.beatUrl = posted.beatUrl;
          job.startSec = posted.startSec ?? startSec;
          job.durationSec = posted.durationSec ?? durationSec;
          this.refreshStemStatus();
          return;
        }
        job.phase = "running";
        this.refreshStemStatus();
        const watch = window.setInterval(() => {
          void fetch(
            `/api/stems/status?trackId=${encodeURIComponent(meta.id)}&role=${role}&start=${Math.round(startSec)}`
          )
            .then((res) => (res.ok ? res.json() : null))
            .then((body: StemJobState | null) => {
              if (!body) return;
              if (body.phase === "ready" && body.vocalsUrl && body.instrumentalUrl) {
                window.clearInterval(watch);
                job.phase = "ready";
                job.vocalsUrl = body.vocalsUrl;
                job.instrumentalUrl = body.instrumentalUrl;
                job.beatUrl = body.beatUrl;
                job.startSec = body.startSec ?? job.startSec;
                job.durationSec = body.durationSec ?? job.durationSec;
                this.refreshStemStatus();
              } else if (body.phase === "error") {
                window.clearInterval(watch);
                job.phase = "error";
                this.refreshStemStatus();
              } else if (body.phase === "running" && job.phase !== "running") {
                job.phase = "running";
                this.refreshStemStatus();
              }
            })
            .catch(() => undefined);
        }, 2000);
        window.setTimeout(() => window.clearInterval(watch), 180_000);
      })
      .catch(() => {
        job.phase = "error";
        this.refreshStemStatus();
      });
  }

  private refreshStemStatus() {
    if (this.stemsReady()) {
      this.stemStatus =
        this.transitionMode === "duet"
          ? "HTDemucs · баттл вокалов"
          : "HTDemucs · инстр A + вокал B · луп";
    }
    else if (this.jobBusy("intro")) this.stemStatus = "HTDemucs · интро";
    else if (this.jobBusy("outro")) this.stemStatus = "HTDemucs · аутро";
    else if (this.jobReady("outro") && !this.next) this.stemStatus = "HTDemucs · аутро готово";
    else if (this.stemsFailed()) this.stemStatus = "HTDemucs · не вышло";
    this.emit();
  }

  private jobsFor(role: "outro" | "intro", trackId: string): StemJobState[] {
    const prefix = `${role}:${trackId}:`;
    const found: StemJobState[] = [];
    for (const [key, job] of this.stemJobs) {
      if (key.startsWith(prefix)) found.push(job);
    }
    return found;
  }

  private coveringJob(
    role: "outro" | "intro",
    trackId: string,
    cue: number,
    needSec: number
  ): StemJobState | null {
    const jobs = this.jobsFor(role, trackId);
    const ready = jobs.find(
      (job) =>
        job.phase === "ready" &&
        job.startSec <= cue + 0.35 &&
        job.startSec + job.durationSec >= cue + Math.min(needSec, 8) - 0.35
    );
    return ready ?? null;
  }

  private jobBusy(role: "outro" | "intro"): boolean {
    for (const [key, job] of this.stemJobs) {
      if (key.startsWith(`${role}:`) && (job.phase === "queued" || job.phase === "running")) return true;
    }
    return false;
  }

  private jobReady(role: "outro" | "intro"): boolean {
    for (const [key, job] of this.stemJobs) {
      if (key.startsWith(`${role}:`) && job.phase === "ready") return true;
    }
    return false;
  }

  private stemsReady(): boolean {
    if (!this.current || !this.next || !this.plan) return false;
    const need = Math.max(4, this.plan.params.blendDurationSec);
    return (
      this.coveringJob("outro", this.current.id, this.plan.params.cueASec, need) != null &&
      this.coveringJob("intro", this.next.id, this.plan.params.cueBSec, need) != null
    );
  }

  private stemsFailed(): boolean {
    if (!this.current || this.jobBusy("outro") || this.jobBusy("intro")) return false;
    const a = this.jobsFor("outro", this.current.id);
    if (a.length > 0 && a.every((job) => job.phase === "error")) return true;
    if (!this.next) return false;
    const b = this.jobsFor("intro", this.next.id);
    return b.length > 0 && b.every((job) => job.phase === "error");
  }

  /** Fetch the ready wavs and arm the engine. Null effect when a window misses the cue. */
  private async armNeural(plan: AIMixPlan): Promise<boolean> {
    this.engine.clearNeuralMashup();
    if (!this.current || !this.next) return false;
    const need = Math.max(4, plan.params.blendDurationSec);
    const a = this.coveringJob("outro", this.current.id, plan.params.cueASec, need);
    const b = this.coveringJob("intro", this.next.id, plan.params.cueBSec, need);
    const duet = this.transitionMode === "duet" || plan.params.dsp.mashupMode === "oneBarDuet";
    const bedUrl = duet ? a.vocalsUrl : a.instrumentalUrl || a.beatUrl;
    const leadUrl = b.vocalsUrl;
    if (!a || !b || !bedUrl || !leadUrl) return false;
    try {
      const bedRes = await fetch(bedUrl);
      const leadRes = await fetch(leadUrl);
      if (!bedRes.ok || !leadRes.ok) return false;
      const bedA = await this.engine.decodeAudio(await bedRes.arrayBuffer());
      const leadB = await this.engine.decodeAudio(await leadRes.arrayBuffer());
      return this.engine.armNeuralMashup({
        duet,
        cueA: plan.params.cueASec,
        cueB: plan.params.cueBSec,
        blendSec: plan.params.blendDurationSec,
        handoffAt: plan.params.handoffAt,
        bedA,
        bedStartSec: a.startSec,
        leadB,
        leadStartSec: b.startSec,
        landFadeSec: (4 * 60) / (plan.params.targetBPM > 30 ? plan.params.targetBPM : 120),
      });
    } catch {
      return false;
    }
  }

  /** Mirror server load phase so Play isn't a silent spinner. */
  private watchLoadPhase(): () => void {
    const timer = window.setInterval(() => {
      void fetch("/api/ym/load")
        .then((r) => r.json())
        .then((body: { label?: string; elapsedSec?: number; phase?: string }) => {
          if (!body.label || body.phase === "idle" || body.phase === "ready") return;
          const sec = Math.round(body.elapsedSec || 0);
          this.setStatus("loading", sec > 0 ? `${body.label} · ${sec} с` : body.label);
        })
        .catch(() => undefined);
    }, 450);
    return () => window.clearInterval(timer);
  }

  private async analyzeDeck(
    id: "a" | "b",
    meta: WaveTrackMeta
  ): Promise<TrackAIProfile> {
    const deck = this.engine.getDeck(id);
    if (!deck.buffer) throw new Error("decode failed");
    const profile = await analyzeTrackBuffer(
      deck.buffer,
      `${meta.artists} — ${meta.title}`
    );
    this.engine.setBpm(id, profile.bpm);
    return profile;
  }

  /** Full load (decode + analyze). Used for B while A already plays. */
  private async loadDeck(
    id: "a" | "b",
    meta: WaveTrackMeta,
    quiet = false
  ): Promise<TrackAIProfile> {
    await this.decodeDeck(id, meta, quiet);
    return this.analyzeDeck(id, meta);
  }

  /** Fetch LRC/Whisper for a track and return the transcript (no profile mutate). */
  private async fetchTranscript(meta: WaveTrackMeta): Promise<TrackTranscript> {
    let lrc: string | undefined;
    try {
      const ly = await fetchJson<{ lrc?: string }>(`/api/ym/lyrics/${meta.id}`);
      lrc = ly.lrc;
    } catch {
      /* no catalog lyrics */
    }
    const fileName = meta.url.split("/").pop() || undefined;
    return fetchJson<TrackTranscript>("/api/whisper/transcribe", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ trackId: meta.id, fileName, lrc }),
    });
  }

  private async transcribeAndRefine(meta: WaveTrackMeta, profile: TrackAIProfile) {
    this.transcriptStatus = "Текст · Whisper / LRC слушает фразу…";
    this.emit();
    try {
      const t = await this.fetchTranscript(meta);
      this.transcriptA = t;
      const neural = withNeuralCue(profile, t, "outgoing");
      if (this.profileA?.name === profile.name || this.current?.id === meta.id) {
        this.profileA = neural;
      }
      if (this.profileB && this.state !== "mixing") {
        await this.planPair({ retarget: true });
      }
      const src =
        t.source === "yandex-lrc"
          ? "LRC · синхрон"
          : t.source === "whisper"
            ? "Whisper · офлайн"
            : "нет текста";
      this.transcriptStatus = `${src} · ${neural.reason}`;
      this.emit();
    } catch (e) {
      this.transcriptStatus =
        e instanceof Error ? `Текст · ${e.message}` : "Текст · ошибка";
      this.emit();
    }
  }

  /** Whisper/LRC for incoming B — drives mixIn so LAND enters on a phrase. */
  private async transcribeIncomingB(meta: WaveTrackMeta, profile: TrackAIProfile) {
    try {
      const t = await this.fetchTranscript(meta);
      if (!this.next || this.next.id !== meta.id) return;
      this.transcriptB = t;
      this.profileB = withNeuralCue(profile, t, "incoming");
      if (this.profileA && this.state !== "mixing") {
        await this.planPair({ retarget: true });
      }
      this.emit();
    } catch {
      /* B lyrics best-effort — energy mixIn remains */
    }
  }

  private async planPair(opts?: { retarget?: boolean }) {
    if (!this.profileA || !this.profileB) throw new Error("Нет профилей A/B");
    // Neural fuse: A exit from lyrics/energy, B entry from its own transcript.
    this.profileA = withNeuralCue(this.profileA, this.transcriptA, "outgoing");
    if (this.transcriptB) {
      this.profileB = withNeuralCue(this.profileB, this.transcriptB, "incoming");
    }
    await this.refreshCoach();
    this.plan =
      this.transitionMode === "duet"
        ? planOneBarDuet(this.profileA, this.profileB)
        : planAutomix(this.profileA, this.profileB);
    this.alignStemToPlan();
    // Coach offsets are for long AutoMix phrases — skip on Phrase Duet.
    if (this.transitionMode !== "duet") {
      applyCoachOffsets(this.plan.params, this.coach);
    }
    const blend = this.plan.params.blendDurationSec;
    recheckMix(
      this.plan,
      vocalLevelNear(this.profileA, this.plan.params.cueASec, Math.min(12, blend)),
      vocalLevelNear(this.profileB, this.plan.params.cueBSec, Math.min(12, blend))
    );
    this.engine.setParams(this.plan.params);
    this.signalPlanReady();
    if (opts?.retarget !== false) this.retargetCueFromPlan();
  }

  /**
   * Runs while A is already playing: deep analyze A, fetch+load B,
   * LRC/Whisper, neural cue, plan mashup, retarget soloUntil.
   */
  private async bootAutomixBrain(gen: number) {
    const brainId = ++this.brainGen;
    this.beginPlanGate();
    this.brainStatus = "Automix · анализ в фоне…";
    this.emit();
    try {
      const metaA = this.current;
      if (!metaA || !this.engine.getDeck("a").buffer) return;

      // 1) Deep A analysis + prefetch next meta in parallel.
      this.brainStatus = "Automix · BPM/key/energy + следующий трек…";
      this.emit();
      const analyzeA = this.analyzeDeck("a", metaA).then((p) => {
        if (brainId !== this.brainGen || gen !== this.loopGen) return p;
        this.profileA = p;
        this.emit();
        return p;
      });
      const fetchB = this.fetchNextTrack().then((m) => {
        if (brainId !== this.brainGen || gen !== this.loopGen) return m;
        this.next = m;
        this.emit();
        return m;
      });
      const [profileA, metaB] = await Promise.all([analyzeA, fetchB]);
      if (brainId !== this.brainGen || gen !== this.loopGen) return;

      // 2) Load+analyze B + Whisper/LRC for A and B in parallel.
      this.brainStatus = "Automix · Whisper + deck B…";
      this.emit();
      const loadB = this.loadDeck("b", metaB, true).then(async (p) => {
        if (brainId !== this.brainGen || gen !== this.loopGen) return p;
        this.profileB = p;
        // B lyrics drive mixIn so LAND opens on a phrase, not a drop slam.
        await this.transcribeIncomingB(metaB, p);
        return this.profileB || p;
      });
      const lyricsA = this.transcribeAndRefine(metaA, profileA);
      await Promise.all([loadB, lyricsA]);
      if (brainId !== this.brainGen || gen !== this.loopGen) return;

      if (!this.plan) {
        await this.planPair({ retarget: true });
      } else {
        this.retargetCueFromPlan();
      }
      this.startCueWatch(gen);
      const blend = this.plan?.params.blendDurationSec;
      this.brainStatus = this.plan
        ? `Automix · готов @ ${this.plan.params.cueASec.toFixed(1)}s` +
          (blend ? ` · ${blend.toFixed(0)}s mashup` : "")
        : "Automix · план не готов";
      this.emit();
    } catch (e) {
      this.brainStatus =
        e instanceof Error ? `Automix · ${e.message}` : "Automix · ошибка";
      this.signalPlanReady();
      this.emit();
    }
  }

  private async finishMashupLog() {
    this.loggingMashup = false;
    if (!this.plan || this.mashupTrail.length < 8) return;
    const report = scoreTransition(this.mashupTrail, {
      mode: this.plan.params.dsp.mashupMode,
      handoffAt: this.plan.params.handoffAt,
      vocalBAt: this.plan.params.dsp.vocalBAt,
      instrAAt: this.plan.params.dsp.instrAAt,
      bassSwapAt: this.plan.params.bassSwapAt,
      nuclearCarve: bakedLeadKill(this.plan.params.dsp),
    });
    this.lastCoachReport = report;
    this.emit();
    try {
      const body = await fetchJson<{
        coach: CoachOffsets;
        learned: boolean;
      }>("/api/mix/log", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          // Duet dual-lead fails AutoMix noDualLead gates — never train on it.
          learn: this.plan.params.dsp.mashupMode !== "oneBarDuet",
          pair: {
            a: this.current ? `${this.current.artists} — ${this.current.title}` : null,
            b: this.next ? `${this.next.artists} — ${this.next.title}` : null,
          },
          report,
        }),
      });
      this.coach = body.coach;
      if (body.learned) {
        this.status = `Coach · ${report.score}/100 · учу смещение · ${report.tweaks.join(", ") || "ok"}`;
      } else {
        this.status = `Coach · ${report.story}`;
      }
      this.emit();
    } catch {
      /* logging best-effort */
    }
  }

  /**
   * Equal-power overlap. Explicit Crossfade uses the last N seconds of A.
   * AutoMix fallback fades whatever tail is still left — it does not rewind.
   */
  private async playFixedCrossfade(
    mode: TransitionMode,
    bodyEnd: number,
    livePlan: AIMixPlan | null,
    liveProfileB: TrackAIProfile | null
  ): Promise<{ ok: boolean; landedAt: number; seconds: number }> {
    const bufferA = this.engine.getDeck("a").buffer;
    const bufferB = this.engine.getDeck("b").buffer;
    if (!bufferA || !bufferB) return { ok: false, landedAt: 0, seconds: this.crossfadeSec };
    const durA = bufferA.duration || 0;
    const xf = this.crossfadeSec;
    const mixIn = Math.max(0, Math.min(liveProfileB?.mixInSec ?? 0, 12));
    let cueA: number;
    let cueB: number;
    let seconds: number;
    if (mode === "crossfade") {
      const planned = Math.max(0, durA - xf);
      cueA = bodyEnd > planned + 0.35 ? Math.min(bodyEnd, Math.max(0, durA - 1)) : planned;
      seconds = Math.min(xf, Math.max(1, durA - cueA));
      cueB = mixIn;
    } else {
      const remain = Math.max(0, durA - bodyEnd);
      seconds = Math.min(xf, Math.max(1, remain > 0.4 ? remain : xf));
      cueA =
        remain > 0.4
          ? Math.max(0, Math.min(bodyEnd, Math.max(0, durA - 0.25)))
          : Math.max(0, durA - seconds);
      cueB = livePlan?.params.cueBSec ?? mixIn;
    }
    const ok = await this.engine.playCrossfade(bufferA, bufferB, cueA, cueB, seconds, (msg) => {
      this.status = msg;
      this.emit();
    });
    return { ok, landedAt: cueB + seconds, seconds };
  }

  /** Start continuous Моя волна with mashup transitions. */
  async start() {
    if (this.running) return;
    const ok = await this.checkAuth();
    if (!ok) return;

    this.running = true;
    const gen = ++this.loopGen;
    this.brainStatus = null;
    this.resetPairState();

    try {
      this.setStatus("loading", "Ищу трек в Моей волне…");
      await fetchJson("/api/ym/wave/reset", { method: "POST" });
      // Fast path: only track A download+decode, then PLAY.
      // Automix brain (analyze / B / lyrics / plan) runs in parallel.
      const stopWatch = this.watchLoadPhase();
      try {
        this.current = await this.fetchNextTrack();
      } finally {
        stopWatch();
      }
      await this.decodeDeck("a", this.current);
      const durA = this.engine.getDeck("a").duration || this.current.durationMs / 1000;
      this.profileA = provisionalProfile(
        durA,
        `${this.current.artists} — ${this.current.title}`
      );
      this.engine.setBpm("a", this.profileA.bpm);

      void this.bootAutomixBrain(gen);

      let resumeFrom = 0;

      while (this.running && gen === this.loopGen) {
        const soft = this.softUntilSec();
        const rate =
          this.transitionMode === "automix" || this.transitionMode === "duet"
            ? (this.plan?.params.rateA ?? 1)
            : 1;

        this.setStatus(
          "playing",
          `${this.current!.artists} — ${this.current!.title}`
        );
        const body = await this.playSeekableUntil(resumeFrom, soft, rate, gen);
        if (body !== "reached") {
          if (gen === this.loopGen) {
            this.running = false;
            if (body === "stopped") {
              this.setStatus("idle", "Стоп");
            }
          }
          return;
        }
        const bodyEnd = this.engine.getSoloPosition();

        // Locals: TS can't see mutations from bootAutomixBrain/planPair.
        let livePlan = this.plan as AIMixPlan | null;
        let liveNext = this.next as WaveTrackMeta | null;
        let liveProfileB = this.profileB as TrackAIProfile | null;

        const wantPlan =
          this.transitionMode === "automix" || this.transitionMode === "duet";
        const durA = this.engine.getDeck("a").duration || this.current!.durationMs / 1000;
        const hopMax = wantPlan ? 18 : 8;
        for (let hop = 0; hop < hopMax && this.running && gen === this.loopGen; hop++) {
          const haveNext = Boolean(this.next && this.engine.getDeck("b").buffer);
          const havePlan = Boolean(this.plan);
          const stemsOk = !wantPlan || this.stemsReady() || this.stemsFailed();
          if (haveNext && (!wantPlan || havePlan) && stemsOk) break;
          const pos = this.engine.getSoloPosition();
          if (pos >= durA - 4) break;
          this.setStatus(
            "playing",
            wantPlan && haveNext && havePlan
              ? "Трек играет · HTDemucs считает окно…"
              : "Трек играет · готовлю переход…"
          );
          const until = Math.min(durA - 0.12, pos + 2);
          const cont = await this.engine.resumeSoloUntil(until);
          if (this.pendingSeek != null || this.scrubbing) {
            const jump = this.pendingSeek ?? this.engine.getSoloPosition();
            this.pendingSeek = null;
            this.scrubbing = false;
            const kept = await this.engine.playSoloUntil(
              "a",
              jump,
              Math.min(durA - 0.12, jump + 2),
              1
            );
            if (!this.running || gen !== this.loopGen) return;
            if (this.pendingSeek != null || this.scrubbing) {
              hop -= 1;
              continue;
            }
            if (!kept) break;
            continue;
          }
          if (!cont) break;
        }
        livePlan = this.plan as AIMixPlan | null;
        liveNext = this.next as WaveTrackMeta | null;
        liveProfileB = this.profileB as TrackAIProfile | null;
        if (livePlan) {
          const pos = this.engine.getSoloPosition();
          if (pos > livePlan.params.cueASec + 0.2) {
            const room = Math.max(4, livePlan.params.blendDurationSec || 8);
            livePlan.params.cueASec = Math.min(pos, Math.max(0, durA - room - 0.3));
          }
        }
        if (!liveNext || !this.engine.getDeck("b").buffer) {
          throw new Error("Следующий трек не готов");
        }

        if (!liveNext) throw new Error("Следующий трек не готов");
        const incoming = liveNext;

        this.stopCueWatch();
        this.brainStatus = null;
        const mode = this.transitionMode;
        let mixed = false;
        let landedAt = 0;
        let playedSec = 1;

        if (mode === "off") {
          // Natural end → next song from the top. No overlap, so this is not "Mixing".
          landedAt = 0;
          mixed = true;
          playedSec = Math.max(1, bodyEnd || this.engine.getDeck("a").duration || 1);
        } else if (mode === "crossfade" || !livePlan) {
          const why = mode === "crossfade" ? "Crossfade" : "Crossfade fallback";
          this.setStatus("mixing", `Mixing · ${why} · → ${incoming.title}`);
          const join = await this.playFixedCrossfade(mode, bodyEnd, livePlan, liveProfileB);
          mixed = join.ok;
          landedAt = join.landedAt;
          playedSec = Math.max(1, bodyEnd || join.seconds);
        } else {
          const neural = await this.armNeural(livePlan);
          this.setStatus(
            "mixing",
            neural
              ? `Mixing · HTDemucs · → ${incoming.title}`
              : `Mixing · ${livePlan.params.dsp.mashupMode} · → ${incoming.title}`
          );
          this.mashupTrail = [];
          this.loggingMashup = true;
          try {
            mixed = await this.engine.playAutoMashup((msg) => {
              this.status = msg;
              this.emit();
            });
            landedAt = livePlan.params.cueBSec + livePlan.params.blendDurationSec;
          } catch (e) {
            console.warn("AutoMix failed, Crossfade fallback", e);
            this.setStatus("mixing", `Mixing · Crossfade fallback · → ${incoming.title}`);
            const join = await this.playFixedCrossfade("automix", bodyEnd, livePlan, liveProfileB);
            mixed = join.ok;
            landedAt = join.landedAt;
          }
          // Never await coach logging before audio handoff — the B tail is short
          // and a network stall was silencing the newly landed track.
          void this.finishMashupLog();
          playedSec = Math.max(
            1,
            (livePlan.params.cueASec || 0) + (livePlan.params.blendDurationSec || 0)
          );
        }
        if (!mixed || !this.running || gen !== this.loopGen) {
          if (gen === this.loopGen) {
            this.running = false;
            if (!mixed) {
              this.setStatus("error", "Сведение не удалось — жми Play");
            }
          }
          return;
        }
        if (!liveProfileB) {
          liveProfileB =
            this.profileB ??
            provisionalProfile(
              this.engine.getDeck("b").duration || incoming.durationMs / 1000,
              `${incoming.artists} — ${incoming.title}`
            );
        }

        const finishedId = this.current!.id;
        void fetchJson("/api/ym/wave/finished", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ trackId: finishedId, playedSec }),
        }).catch(() => undefined);

        // Handoff FIRST while mashup/crossfade B is still draining — then bookkeeping.
        this.engine.promoteBToA();
        this.current = incoming;
        this.queueStemWindow("a", incoming);
        this.profileA = liveProfileB;
        const landedProfile = this.profileA as TrackAIProfile;
        const provisionalUntil = Math.min(
          landedProfile.durationSec - 0.5,
          Math.max(landedAt + 20, landedProfile.mixOutSec - 0.5)
        );
        this.setStatus(
          "playing",
          `${incoming.artists} — ${incoming.title}`
        );
        let soloFrom = landedAt;

        // Promoted B becomes A — keep its transcript as the new outgoing cue source.
        this.transcriptA = this.transcriptB;
        this.transcriptB = null;
        this.resetPairState();
        this.transcriptStatus = this.transcriptA
          ? `Текст · ${this.transcriptA.source} готов для следующего cue`
          : "Текст · Whisper слушает следующий…";
        this.brainStatus = "Automix · готовлю следующий mashup…";
        this.beginPlanGate();
        if (this.current && this.profileA && !this.transcriptA) {
          void this.transcribeAndRefine(this.current, this.profileA);
        }
        this.emit();

        const prefetch = (async () => {
          try {
            this.next = await this.fetchNextTrack();
            this.emit();
            this.profileB = await this.loadDeck("b", this.next, true);
            if (!this.running || gen !== this.loopGen) return;
            await this.transcribeIncomingB(this.next, this.profileB);
            if (!this.running || gen !== this.loopGen) return;
            await this.planPair({ retarget: true });
            this.startCueWatch(gen);
            const blend = this.plan?.params.blendDurationSec;
            this.brainStatus = this.plan
              ? `Automix · готов @ ${this.plan.params.cueASec.toFixed(1)}s` +
                (blend ? ` · ${blend.toFixed(0)}s` : "")
              : "Automix · план не готов · Crossfade";
            this.emit();
          } catch (e) {
            this.brainStatus =
              e instanceof Error ? `Automix · ${e.message} · Crossfade` : "Automix · Crossfade";
            this.signalPlanReady();
            this.emit();
          }
        })();

        let soloEnded = false;
        while (this.running && gen === this.loopGen) {
          const ended = await this.engine.playSoloUntil("a", soloFrom, provisionalUntil, 1);
          if (!this.running || gen !== this.loopGen) return;
          if (this.pendingSeek != null || this.scrubbing) {
            soloFrom = this.pendingSeek ?? this.engine.getSoloPosition();
            this.pendingSeek = null;
            this.scrubbing = false;
            continue;
          }
          soloEnded = ended;
          break;
        }
        if (!soloEnded) {
          if (gen === this.loopGen) {
            this.running = false;
            this.setStatus("idle", "Стоп");
          }
          return;
        }
        await prefetch;
        if (!this.running || gen !== this.loopGen) return;
        const readyPlan = this.plan as AIMixPlan | null;

        resumeFrom = this.engine.getSoloPosition();
        if (
          (this.transitionMode === "automix" || this.transitionMode === "duet") &&
          readyPlan
        ) {
          const cue = readyPlan.params.cueASec;
          // Snap only a tiny overshoot — never rewind far behind the playhead
          // (that forced an instant remash with stop()+bake silence).
          if (resumeFrom >= cue - 0.2 && resumeFrom <= cue + 1.5) {
            resumeFrom = cue;
          } else if (resumeFrom > cue + 1.5) {
            readyPlan.params.cueASec = resumeFrom;
            this.engine.setParams(readyPlan.params);
          }
        }
      }
      // Natural loop exit — clear running so Play can restart.
      if (gen === this.loopGen) {
        this.running = false;
        this.setStatus("idle", "Волна на паузе · жми Play");
      }
    } catch (e) {
      if (gen !== this.loopGen) return;
      this.running = false;
      this.engine.stop();
      this.setStatus("error", e instanceof Error ? e.message : String(e));
    }
  }

  /** Resume AudioContext after tab blur / DevTools — keeps Automix from dying silent. */
  async resumeAudio() {
    if (
      this.state === "playing" ||
      this.state === "mixing" ||
      this.state === "loading"
    ) {
      try {
        await this.engine.ensureContext();
      } catch {
        /* ignore */
      }
    }
  }

  stop() {
    this.running = false;
    this.loopGen++;
    this.brainGen++;
    this.pendingSeek = null;
    this.scrubbing = false;
    this.loggingMashup = false;
    this.brainStatus = null;
    this.stopCueWatch();
    this.signalPlanReady();
    this.engine.stop();
    this.setStatus("idle", "Стоп");
  }

  async skip() {
    const cur = this.current;
    const played = this.lastEngine?.displayElapsed ?? 0;
    if (cur) {
      void fetchJson("/api/ym/wave/skip", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ trackId: cur.id, playedSec: played }),
      }).catch(() => undefined);
    }
    this.stop();
    await this.start();
  }
}
