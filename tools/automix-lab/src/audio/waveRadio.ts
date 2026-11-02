/**
 * Continuous «Моя волна» radio with DJ mashup handoffs.
 *
 * PLAY current → near mixOut → LOCK…MASHUP…LAND → promote B → prefetch next → …
 * Dual mashup only when A outro is instrumental; else Safe Exit (phrase Automix).
 */
import { AutomixEngine, type EngineSnapshot } from "./engine";
import { analyzeTrackBuffer, type TrackAIProfile } from "./analyzeTrack";
import { planAutomix, recheckMix, vocalLevelNear, type AIMixPlan } from "./aiMixEngine";
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
  /** Why we are not on FLAC (geo soft-downgrade, error, …). */
  qualityNote?: string;
};

export type WaveRadioState =
  | "idle"
  | "needAuth"
  | "loading"
  | "playing"
  | "mixing"
  | "error";

/** Apple Music Song Transitions: AutoMix | Crossfade | Off. */
export type TransitionMode = "automix" | "crossfade" | "off";

const TRANSITION_KEY = "sonivo-song-transitions";

const CROSSFADE_KEY = "sonivo-song-transitions-sec";

function loadTransitionMode(): TransitionMode {
  try {
    const v = localStorage.getItem(TRANSITION_KEY);
    if (v === "automix" || v === "crossfade" || v === "off") return v;
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
  /** Max scrub position (= automixAtSec - epsilon while playing body). */
  scrubMaxSec: number | null;
  canSeek: boolean;
  transcript: TrackTranscript | null;
  transcriptStatus: string | null;
  /** Background Automix brain phase (runs while song plays). */
  brainStatus: string | null;
  cueWords: TranscriptWord[];
  engine: EngineSnapshot | null;
  /** Apple-style Song Transitions mode. */
  transitionMode: TransitionMode;
  /** Fixed crossfade length when mode=crossfade (1…12). */
  crossfadeSec: number;
};

type Listener = (s: WaveRadioSnapshot) => void;

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
  private brainGen = 0;
  private pendingSeek: number | null = null;
  private scrubbing = false;
  private planReady: Promise<void> | null = null;
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

  snapshot(): WaveRadioSnapshot {
    return {
      state: this.state,
      status: this.status,
      current: this.current,
      next: this.next,
      phase: this.lastEngine?.phase ?? "",
      mixing: this.state === "mixing",
      progress: this.lastEngine?.progress ?? 0,
      elapsed: this.lastEngine?.displayElapsed ?? 0,
      duration: this.lastEngine?.displayDuration ?? 0,
      planMode: this.plan?.params.dsp.mashupMode ?? null,
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
      canSeek: this.state === "playing" && !this.loggingMashup && this.automixAt() != null,
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
    };
  }

  getTransitionMode(): TransitionMode {
    return this.transitionMode;
  }

  setTransitionMode(mode: TransitionMode) {
    if (mode !== "automix" && mode !== "crossfade" && mode !== "off") return;
    this.transitionMode = mode;
    try {
      localStorage.setItem(TRANSITION_KEY, mode);
    } catch {
      /* ignore */
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

  private scrubMax(): number | null {
    const at = this.automixAt();
    if (at == null) return null;
    return Math.max(0, at - 0.35);
  }

  /**
   * Scrub current track. Only allowed before Automix cue (not during mashup).
   */
  seekTo(sec: number) {
    if (this.state !== "playing" || this.loggingMashup) return;
    const max = this.scrubMax();
    if (max == null) return;
    const clamped = Math.max(0, Math.min(sec, max));
    this.pendingSeek = clamped;
    this.scrubbing = true;
    this.engine.interruptSolo();
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
    if (this.transitionMode === "automix" && this.plan) {
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
      const until =
        this.transitionMode === "automix"
          ? (this.plan?.params.cueASec ?? softUntilSec)
          : softUntilSec;
      if (from >= until - 0.25) return "reached";
      const start = this.pendingSeek != null ? this.pendingSeek : from;
      this.pendingSeek = null;
      this.scrubbing = false;
      const reached = await this.engine.playSoloUntil("a", start, until, rate);
      if (!this.running || gen !== this.loopGen) return "aborted";
      if (this.pendingSeek != null || this.scrubbing) {
        from = this.pendingSeek ?? start;
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
    this.planReady = new Promise<void>((resolve) => {
      this.planReadyResolve = resolve;
    });
  }

  private signalPlanReady() {
    this.planReadyResolve?.();
    this.planReadyResolve = null;
  }

  private async waitForPlan(gen: number, ms = 90_000): Promise<boolean> {
    if (this.plan && this.profileB) return true;
    const gate = this.planReady;
    if (!gate) return Boolean(this.plan && this.profileB);
    let timedOut = false;
    const timer = window.setTimeout(() => {
      timedOut = true;
      this.signalPlanReady();
    }, ms);
    await gate;
    window.clearTimeout(timer);
    if (!this.running || gen !== this.loopGen) return false;
    return Boolean(this.plan && this.profileB) && !timedOut;
  }

  /** Hot-retarget Automix cue while the song is playing. */
  private retargetCueFromPlan() {
    if (!this.plan || this.state === "mixing") return;
    if (this.transitionMode !== "automix") {
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
      const nextSafe = Math.min(dur - 4, pos + 4.5);
      target = nextSafe;
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
      this.setStatus("loading", `Загрузка · ${meta.artists} — ${meta.title}`);
    }
    const r = await fetch(meta.url);
    if (!r.ok) throw new Error(`Не скачался ${meta.title}`);
    const buf = await r.arrayBuffer();
    await this.engine.loadArrayBuffer(id, buf, meta.fileName);
    if (!this.engine.getDeck(id).buffer) throw new Error("decode failed");
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
    this.plan = planAutomix(this.profileA, this.profileB);
    applyCoachOffsets(this.plan.params, this.coach);
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
          learn: true,
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
      await fetchJson("/api/ym/wave/reset", { method: "POST" });
      // Fast path: only track A download+decode, then PLAY.
      // Automix brain (analyze / B / lyrics / plan) runs in parallel.
      this.current = await this.fetchNextTrack();
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
        const rate = this.transitionMode === "automix" ? (this.plan?.params.rateA ?? 1) : 1;

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

        if (!liveNext || !this.engine.getDeck("b").buffer) {
          this.setStatus("loading", "Жду следующий трек…");
          await this.waitForPlan(gen, this.transitionMode === "automix" ? 90_000 : 25_000);
          livePlan = this.plan as AIMixPlan | null;
          liveNext = this.next as WaveTrackMeta | null;
          liveProfileB = this.profileB as TrackAIProfile | null;
          if (!liveNext || !this.engine.getDeck("b").buffer) {
            throw new Error("Следующий трек не готов");
          }
        } else if (this.transitionMode === "automix" && !livePlan) {
          this.setStatus("loading", "Automix · добираю план сведения…");
          await this.waitForPlan(gen);
          livePlan = this.plan as AIMixPlan | null;
          liveNext = this.next as WaveTrackMeta | null;
          liveProfileB = this.profileB as TrackAIProfile | null;
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
          this.setStatus(
            "mixing",
            `Mixing · ${livePlan.params.dsp.mashupMode} · → ${incoming.title}`
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
          await this.finishMashupLog();
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

        this.engine.promoteBToA();
        this.current = incoming;
        this.profileA = liveProfileB;
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

        // Keep audio alive while next track downloads + analyzes.
        const landedProfile = this.profileA as TrackAIProfile;
        const provisionalUntil = Math.min(
          landedProfile.durationSec - 0.5,
          Math.max(landedAt + 20, landedProfile.mixOutSec - 0.5)
        );
        this.setStatus(
          "playing",
          `${incoming.artists} — ${incoming.title}`
        );
        const soloP = this.engine.playSoloUntil("a", landedAt, provisionalUntil, 1);

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

        await Promise.all([soloP, prefetch]);
        if (!this.running || gen !== this.loopGen) return;
        const readyPlan = this.plan as AIMixPlan | null;

        resumeFrom = this.engine.getSoloPosition();
        if (
          this.transitionMode === "automix" &&
          readyPlan &&
          resumeFrom >= readyPlan.params.cueASec - 0.2
        ) {
          resumeFrom = readyPlan.params.cueASec;
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
