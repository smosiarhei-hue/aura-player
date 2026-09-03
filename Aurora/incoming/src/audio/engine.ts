import type { MixSettings, MixStyle, Track, TransitionState } from "../types";

type DeckId = "A" | "B";

interface Glide { t0: number; t1: number; r0: number; r1: number }

class Deck {
  id: DeckId;
  ctx: AudioContext;
  input: GainNode; // trim (автогейн)
  hp: BiquadFilterNode;
  low: BiquadFilterNode;
  gain: GainNode;
  echoSend: GainNode;
  analyser: AnalyserNode;
  source: AudioBufferSourceNode | null = null;
  track: Track | null = null;
  startCtx = 0;
  startOffset = 0;
  rate = 1;
  glide: Glide | null = null;
  private levelBuf = new Uint8Array(256);

  constructor(id: DeckId, ctx: AudioContext, master: AudioNode, echoIn: AudioNode) {
    this.id = id;
    this.ctx = ctx;
    this.input = ctx.createGain();
    this.hp = ctx.createBiquadFilter();
    this.hp.type = "highpass";
    this.hp.frequency.value = 20;
    this.hp.Q.value = 0.7;
    this.low = ctx.createBiquadFilter();
    this.low.type = "lowshelf";
    this.low.frequency.value = 220;
    this.low.gain.value = 0;
    this.gain = ctx.createGain();
    this.gain.gain.value = 0;
    this.echoSend = ctx.createGain();
    this.echoSend.gain.value = 0;
    this.analyser = ctx.createAnalyser();
    this.analyser.fftSize = 256;

    this.input.connect(this.hp);
    this.hp.connect(this.low);
    this.low.connect(this.gain);
    this.gain.connect(this.analyser);
    this.analyser.connect(master);
    this.gain.connect(this.echoSend);
    this.echoSend.connect(echoIn);
  }

  get isPlaying() {
    return !!this.source;
  }

  /** Текущая позиция в треке (с учётом плавного изменения скорости) */
  position(now = this.ctx.currentTime): number {
    if (!this.source) return 0;
    const g = this.glide;
    if (!g || now <= g.t0) return this.startOffset + this.rate * (now - this.startCtx);
    const base = this.startOffset + this.rate * (g.t0 - this.startCtx);
    const dur = g.t1 - g.t0;
    if (now < g.t1) {
      const dt = now - g.t0;
      return base + g.r0 * dt + ((g.r1 - g.r0) * dt * dt) / (2 * dur);
    }
    const full = ((g.r0 + g.r1) / 2) * dur;
    return base + full + g.r1 * (now - g.t1);
  }

  /** Эффективный BPM с учётом текущей скорости */
  effectiveRate(now = this.ctx.currentTime): number {
    const g = this.glide;
    if (!g || now <= g.t0) return this.rate;
    if (now >= g.t1) return g.r1;
    return g.r0 + ((g.r1 - g.r0) * (now - g.t0)) / (g.t1 - g.t0);
  }

  /** Перевод времени трека -> время AudioContext (до глайда) */
  ctxTimeFor(trackTime: number): number {
    const now = this.ctx.currentTime;
    const pos = this.position(now);
    return now + (trackTime - pos) / this.effectiveRate(now);
  }

  start(track: Track, offset: number, when: number, rate: number, trim: number) {
    this.stop();
    if (!track.buffer) return;
    const src = this.ctx.createBufferSource();
    src.buffer = track.buffer;
    src.playbackRate.value = rate;
    src.connect(this.input);
    src.start(when, Math.max(0, offset));
    this.source = src;
    this.track = track;
    this.startCtx = when;
    this.startOffset = offset;
    this.rate = rate;
    this.glide = null;
    this.input.gain.value = trim;
    src.onended = () => {
      if (this.source === src) {
        this.source = null;
      }
    };
  }

  scheduleGlide(t0: number, t1: number, toRate: number) {
    if (!this.source) return;
    const p = this.source.playbackRate;
    p.cancelScheduledValues(t0);
    p.setValueAtTime(this.rate, t0);
    p.linearRampToValueAtTime(toRate, t1);
    this.glide = { t0, t1, r0: this.rate, r1: toRate };
  }

  stop(at?: number) {
    const src = this.source;
    if (!src) return;
    try {
      src.stop(at ?? this.ctx.currentTime);
    } catch {
      /* ignore */
    }
    if (at === undefined) {
      src.disconnect();
      this.source = null;
    }
  }

  reset(now: number) {
    for (const p of [this.gain.gain, this.low.gain, this.hp.frequency, this.echoSend.gain]) p.cancelScheduledValues(now);
    this.gain.gain.setValueAtTime(this.gain.gain.value, now);
    this.low.gain.setValueAtTime(0, now);
    this.hp.frequency.setValueAtTime(20, now);
    this.echoSend.gain.setValueAtTime(0, now);
  }

  level(): number {
    this.analyser.getByteTimeDomainData(this.levelBuf);
    let peak = 0;
    for (let i = 0; i < this.levelBuf.length; i++) {
      const v = Math.abs(this.levelBuf[i] - 128) / 128;
      if (v > peak) peak = v;
    }
    return peak;
  }
}

export interface EngineSnapshot {
  position: number;
  duration: number;
  playing: boolean;
  activeDeck: DeckId;
  levels: { A: number; B: number };
  transition: TransitionState;
  effectiveBpm: number;
}

type Listener = (evt: { type: "trackChange" | "transitionStart" | "transitionEnd" | "ended"; track?: Track }) => void;

const equalPowerOut = new Float32Array(128).map((_, i) => Math.cos(((i / 127) * Math.PI) / 2));
const equalPowerIn = new Float32Array(128).map((_, i) => Math.sin(((i / 127) * Math.PI) / 2));

export class AutoMixEngine {
  ctx: AudioContext;
  master: GainNode;
  limiter: DynamicsCompressorNode;
  analyser: AnalyserNode;
  decks: Record<DeckId, Deck>;
  active: DeckId = "A";
  nextTrack: Track | null = null;
  settings: MixSettings;
  transition: TransitionState = {
    active: false,
    fromId: null,
    toId: null,
    progress: 0,
    startedAt: 0,
    duration: 0,
    tempoShift: 0,
    style: "smooth",
  };
  private listeners: Listener[] = [];
  private freqBuf: Uint8Array<ArrayBuffer>;
  private endedFired = false;
  private transitionScheduledFor: string | null = null;
  private echoDelay: DelayNode;
  private echoFeedback: GainNode;
  private echoFilter: BiquadFilterNode;
  private pendingSwitch: { at: number; to: DeckId; stopOutAt: number } | null = null;

  constructor(settings: MixSettings) {
    const Ctx = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    this.ctx = new Ctx({ latencyHint: "playback" });
    this.settings = settings;
    this.master = this.ctx.createGain();
    this.master.gain.value = 0.9;
    this.limiter = this.ctx.createDynamicsCompressor();
    this.limiter.threshold.value = -8;
    this.limiter.knee.value = 12;
    this.limiter.ratio.value = 6;
    this.limiter.attack.value = 0.003;
    this.limiter.release.value = 0.2;
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 512;
    this.analyser.smoothingTimeConstant = 0.82;
    this.freqBuf = new Uint8Array(this.analyser.frequencyBinCount);

    // эхо-шина
    this.echoDelay = this.ctx.createDelay(2);
    this.echoDelay.delayTime.value = 0.375;
    this.echoFeedback = this.ctx.createGain();
    this.echoFeedback.gain.value = 0.55;
    this.echoFilter = this.ctx.createBiquadFilter();
    this.echoFilter.type = "lowpass";
    this.echoFilter.frequency.value = 3500;
    this.echoDelay.connect(this.echoFilter);
    this.echoFilter.connect(this.echoFeedback);
    this.echoFeedback.connect(this.echoDelay);
    this.echoFilter.connect(this.master);

    this.master.connect(this.limiter);
    this.limiter.connect(this.analyser);
    this.analyser.connect(this.ctx.destination);

    this.decks = {
      A: new Deck("A", this.ctx, this.master, this.echoDelay),
      B: new Deck("B", this.ctx, this.master, this.echoDelay),
    };
  }

  on(l: Listener) {
    this.listeners.push(l);
    return () => {
      this.listeners = this.listeners.filter((x) => x !== l);
    };
  }
  private emit(evt: Parameters<Listener>[0]) {
    this.listeners.forEach((l) => l(evt));
  }

  async resume() {
    if (this.ctx.state !== "running") await this.ctx.resume();
  }

  get activeDeck() {
    return this.decks[this.active];
  }
  get currentTrack() {
    return this.activeDeck.track;
  }
  get playing() {
    return this.ctx.state === "running" && this.activeDeck.isPlaying;
  }

  private trimFor(track: Track): number {
    if (!this.settings.autoGain || !track.analysis) return 1;
    const target = -17;
    const g = Math.pow(10, (target - track.analysis.loudnessDb) / 20);
    return Math.min(2.2, Math.max(0.35, g));
  }

  /** Немедленно включить трек (без перехода) */
  async play(track: Track, fromStart = true) {
    await this.resume();
    const now = this.ctx.currentTime;
    this.cancelTransition();
    for (const d of Object.values(this.decks)) {
      d.stop();
      d.reset(now);
      d.gain.gain.setValueAtTime(0, now);
    }
    const deck = this.decks[this.active];
    const offset = fromStart ? 0 : track.analysis?.mixIn ?? 0;
    deck.start(track, offset, now + 0.02, 1, this.trimFor(track));
    deck.gain.gain.setValueAtTime(0, now);
    deck.gain.gain.linearRampToValueAtTime(1, now + 0.08);
    this.endedFired = false;
    this.transitionScheduledFor = null;
    this.emit({ type: "trackChange", track });
  }

  async togglePlay() {
    if (this.ctx.state === "running") await this.ctx.suspend();
    else await this.ctx.resume();
  }

  seek(time: number) {
    const deck = this.activeDeck;
    const track = deck.track;
    if (!track || this.transition.active) return;
    const now = this.ctx.currentTime;
    const rate = deck.effectiveRate(now);
    deck.start(track, Math.max(0, Math.min(track.duration - 0.05, time)), now + 0.01, rate, this.trimFor(track));
    deck.gain.gain.cancelScheduledValues(now);
    deck.gain.gain.setValueAtTime(1, now);
    this.endedFired = false;
    this.transitionScheduledFor = null;
  }

  private cancelTransition() {
    this.transition = { ...this.transition, active: false };
    this.pendingSwitch = null;
  }

  /** Запуск перехода на nextTrack на ближайшем бите */
  startTransition(next?: Track, styleOverride?: MixStyle): boolean {
    const target = next ?? this.nextTrack;
    const out = this.activeDeck;
    if (!target || !target.buffer || !target.analysis || !out.track || !out.isPlaying || this.transition.active) return false;
    const inn = this.decks[this.active === "A" ? "B" : "A"];
    const s = this.settings;
    const style = styleOverride ?? s.style;
    const now = this.ctx.currentTime;

    const outA = out.track.analysis;
    const outRate = out.effectiveRate(now);
    const outBpm = (outA?.bpm ?? 120) * outRate;
    const beat = 60 / outBpm;

    // --- битмэтчинг ---
    let rate = 1;
    if (s.beatmatch) {
      let r = outBpm / target.analysis.bpm;
      if (r > 1.45) r /= 2;
      if (r < 0.69) r *= 2;
      rate = Math.min(1.08, Math.max(0.92, r));
    }

    // --- время старта: следующий бит (для club/cut — ближайшая «единица» такта) ---
    const pos = out.position(now);
    const grid = outA?.beatOffset ?? 0;
    const beatTrack = 60 / (outA?.bpm ?? 120);
    const quant = style === "club" || style === "cut" ? 4 : 1;
    const k = Math.ceil((pos + 0.06 * outRate - grid) / (beatTrack * quant));
    let startTrack = grid + k * beatTrack * quant;
    if (startTrack > out.track.duration - 0.2) startTrack = pos + 0.05;
    const t0 = Math.max(now + 0.01, out.ctxTimeFor(startTrack));

    // --- длительность ---
    let D: number;
    switch (style) {
      case "cut":
        D = beat * 0.5;
        break;
      case "echo":
        D = beat * 2;
        break;
      case "club":
        D = beat * Math.max(4, s.lengthBeats);
        break;
      default:
        D = beat * Math.max(4, s.lengthBeats);
    }
    const remaining = (out.track.duration - startTrack) / outRate;
    D = Math.max(0.15, Math.min(D, remaining - 0.05));
    const t1 = t0 + D;

    // --- входящая дека ---
    const inOffset = target.analysis.mixIn;
    inn.reset(now);
    inn.start(target, inOffset, t0, rate, this.trimFor(target));
    const gIn = inn.gain.gain;
    const gOut = out.gain.gain;
    gIn.cancelScheduledValues(now);
    gOut.cancelScheduledValues(now);
    gIn.setValueAtTime(0, now);
    gOut.setValueAtTime(gOut.value, now);
    const pre = t0 - 0.002;

    if (style === "cut") {
      gIn.setValueAtTime(0, pre);
      gIn.linearRampToValueAtTime(1, t0 + 0.01);
      gOut.setValueAtTime(1, pre);
      gOut.linearRampToValueAtTime(0, t0 + D);
    } else {
      gIn.setValueAtTime(0, pre);
      gIn.setValueCurveAtTime(equalPowerIn, t0, D);
      gOut.setValueAtTime(1, pre);
      gOut.setValueCurveAtTime(equalPowerOut, t0, D);
    }

    // --- EQ swap: басы уходящего убираем, входящего — вводим ---
    if (s.eqSwap && style !== "cut") {
      const lo = out.low.gain;
      const li = inn.low.gain;
      lo.cancelScheduledValues(now);
      li.cancelScheduledValues(now);
      if (style === "club") {
        // резкий обмен басами в середине перехода
        const swap = t0 + D * 0.5;
        li.setValueAtTime(-26, t0);
        li.setValueAtTime(-26, swap - beat * 0.5);
        li.linearRampToValueAtTime(0, swap);
        lo.setValueAtTime(0, t0);
        lo.setValueAtTime(0, swap - beat * 0.5);
        lo.linearRampToValueAtTime(-30, swap);
        // хай-пасс уходящего уезжает вверх к концу
        out.hp.frequency.setValueAtTime(20, swap);
        out.hp.frequency.exponentialRampToValueAtTime(900, t1);
      } else {
        li.setValueAtTime(-18, t0);
        li.setValueAtTime(-18, t0 + D * 0.35);
        li.linearRampToValueAtTime(0, t0 + D * 0.85);
        lo.setValueAtTime(0, t0);
        lo.setValueAtTime(0, t0 + D * 0.15);
        lo.linearRampToValueAtTime(-20, t0 + D * 0.7);
        out.hp.frequency.setValueAtTime(20, t0 + D * 0.5);
        out.hp.frequency.exponentialRampToValueAtTime(500, t1);
      }
    }

    // --- эхо-аут ---
    let stopOutAt = t1 + 0.1;
    if (style === "echo") {
      this.echoDelay.delayTime.setValueAtTime(beat * 0.75, now);
      const send = out.echoSend.gain;
      send.cancelScheduledValues(now);
      send.setValueAtTime(0, t0 - 0.001);
      send.linearRampToValueAtTime(0.9, t0 + 0.02);
      send.setValueAtTime(0.9, t1);
      send.linearRampToValueAtTime(0, t1 + 0.05);
      this.echoFeedback.gain.setValueAtTime(0.62, now);
      stopOutAt = t1 + 0.1; // хвост живёт в шине задержки
    }

    // --- возврат темпа к оригиналу после перехода ---
    if (Math.abs(rate - 1) > 0.001) {
      inn.scheduleGlide(t1 + 0.05, t1 + 0.05 + Math.max(6, D), 1);
    }

    out.stop(stopOutAt);
    this.pendingSwitch = { at: t1, to: inn.id, stopOutAt };
    this.transition = {
      active: true,
      fromId: out.track.id,
      toId: target.id,
      progress: 0,
      startedAt: t0,
      duration: D,
      tempoShift: (rate - 1) * 100,
      style,
    };
    this.transitionScheduledFor = out.track.id;
    this.emit({ type: "transitionStart", track: target });
    return true;
  }

  /** Вызывается из rAF-цикла UI */
  update(): EngineSnapshot {
    const now = this.ctx.currentTime;
    const out = this.activeDeck;
    const tr = this.transition;

    if (tr.active) {
      tr.progress = Math.max(0, Math.min(1, (now - tr.startedAt) / tr.duration));
      if (this.pendingSwitch && now >= this.pendingSwitch.at) {
        const from = this.decks[this.active];
        this.active = this.pendingSwitch.to;
        this.pendingSwitch = null;
        this.transition = { ...tr, active: false, progress: 1 };
        this.endedFired = false;
        this.transitionScheduledFor = null;
        // источник уходящей деки остановлен по расписанию (stopOutAt); чистим состояние
        from.source = null;
        from.reset(this.ctx.currentTime);
        this.emit({ type: "trackChange", track: this.activeDeck.track ?? undefined });
        this.emit({ type: "transitionEnd" });
      }
    } else if (out.track && out.isPlaying && this.ctx.state === "running") {
      const a = out.track.analysis;
      const pos = out.position(now);
      const beat = a ? 60 / a.bpm : 0.5;
      const style = this.settings.style;
      const plannedBeats = style === "cut" ? 0.5 : style === "echo" ? 2 : Math.max(4, this.settings.lengthBeats);
      const quant = style === "club" || style === "cut" ? 4 : 1;
      // Гарантируем, что переход успеет прозвучать целиком до конца трека
      const latest = out.track.duration - plannedBeats * beat - 0.3;
      const mixOut = Math.min(a ? a.mixOut : out.track.duration - 10, latest);
      if (this.nextTrack && this.nextTrack.buffer && this.nextTrack.analysis && this.transitionScheduledFor !== out.track.id) {
        if (pos >= mixOut - beat * quant * 1.02) {
          this.startTransition();
        }
      } else if (pos >= out.track.duration - 0.05 && !this.endedFired) {
        this.endedFired = true;
        this.emit({ type: "ended", track: out.track });
      }
    }

    const cur = this.activeDeck;
    const a = cur.track?.analysis;
    return {
      position: cur.position(now),
      duration: cur.track?.duration ?? 0,
      playing: this.ctx.state === "running" && cur.isPlaying,
      activeDeck: this.active,
      levels: { A: this.decks.A.level(), B: this.decks.B.level() },
      transition: { ...this.transition },
      effectiveBpm: a ? a.bpm * cur.effectiveRate(now) : 0,
    };
  }

  spectrum(): Uint8Array<ArrayBuffer> {
    this.analyser.getByteFrequencyData(this.freqBuf);
    return this.freqBuf;
  }

  setVolume(v: number) {
    this.master.gain.setTargetAtTime(v, this.ctx.currentTime, 0.02);
  }
}
