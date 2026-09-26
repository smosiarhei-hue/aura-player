import type { MixSettings, MixStyle, Track, TransitionState } from "../types";

type DeckId = "A" | "B";

interface Glide { t0: number; t1: number; r0: number; r1: number }

/** Генератор натурального стерео импульса реверберации */
function createReverbImpulse(ctx: AudioContext, duration = 3.0, decay = 2.0): AudioBuffer {
  const rate = ctx.sampleRate;
  const length = Math.floor(rate * duration);
  const impulse = ctx.createBuffer(2, length, rate);
  const left = impulse.getChannelData(0);
  const right = impulse.getChannelData(1);

  for (let i = 0; i < length; i++) {
    const t = i / rate;
    const env = Math.exp(-t * decay);
    left[i] = (Math.random() * 2 - 1) * env;
    right[i] = (Math.random() * 2 - 1) * env;
  }
  return impulse;
}

class Deck {
  id: DeckId;
  ctx: AudioContext;
  input: GainNode; // trim (автогейн)
  hp: BiquadFilterNode;
  lp: BiquadFilterNode;
  low: BiquadFilterNode;
  mid: BiquadFilterNode; // подавление/выделение вокала (1.2 кГц)
  gain: GainNode;
  echoSend: GainNode;
  reverbSend: GainNode;
  analyser: AnalyserNode;
  source: AudioBufferSourceNode | null = null;
  track: Track | null = null;
  startCtx = 0;
  startOffset = 0;
  rate = 1;
  glide: Glide | null = null;
  private levelBuf = new Uint8Array(256);

  constructor(id: DeckId, ctx: AudioContext, master: AudioNode, echoIn: AudioNode, reverbIn: AudioNode) {
    this.id = id;
    this.ctx = ctx;
    this.input = ctx.createGain();
    this.hp = ctx.createBiquadFilter();
    this.hp.type = "highpass";
    this.hp.frequency.value = 20;
    this.hp.Q.value = 0.7;
    this.lp = ctx.createBiquadFilter();
    this.lp.type = "lowpass";
    this.lp.frequency.value = 20000;
    this.lp.Q.value = 0.7;
    this.low = ctx.createBiquadFilter();
    this.low.type = "lowshelf";
    this.low.frequency.value = 220;
    this.low.gain.value = 0;
    this.mid = ctx.createBiquadFilter();
    this.mid.type = "peaking";
    this.mid.frequency.value = 1200;
    this.mid.Q.value = 0.7;
    this.mid.gain.value = 0;
    this.gain = ctx.createGain();
    this.gain.gain.value = 0;
    this.echoSend = ctx.createGain();
    this.echoSend.gain.value = 0;
    this.reverbSend = ctx.createGain();
    this.reverbSend.gain.value = 0;
    this.analyser = ctx.createAnalyser();
    this.analyser.fftSize = 256;

    this.input.connect(this.hp);
    this.hp.connect(this.lp);
    this.lp.connect(this.low);
    this.low.connect(this.mid);
    this.mid.connect(this.gain);
    this.gain.connect(this.analyser);
    this.analyser.connect(master);
    this.mid.connect(this.echoSend);
    this.echoSend.connect(echoIn);
    this.mid.connect(this.reverbSend);
    this.reverbSend.connect(reverbIn);
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
    for (const p of [
      this.gain.gain,
      this.low.gain,
      this.mid.gain,
      this.hp.frequency,
      this.hp.Q,
      this.lp.frequency,
      this.lp.Q,
      this.echoSend.gain,
      this.reverbSend.gain,
    ]) {
      p.cancelScheduledValues(now);
    }
    this.gain.gain.setValueAtTime(this.gain.gain.value, now);
    this.low.gain.setValueAtTime(0, now);
    this.mid.gain.setValueAtTime(0, now);
    this.hp.frequency.setValueAtTime(20, now);
    this.hp.Q.setValueAtTime(0.7, now);
    this.lp.frequency.setValueAtTime(20000, now);
    this.lp.Q.setValueAtTime(0.7, now);
    this.echoSend.gain.setValueAtTime(0, now);
    this.reverbSend.gain.setValueAtTime(0, now);
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
    plannedBars: 8,
    plannedBeats: 32,
    currentBar: 1,
    currentBeat: 1,
    description: "",
  };
  private listeners: Listener[] = [];
  private freqBuf: Uint8Array<ArrayBuffer>;
  private endedFired = false;
  private transitionScheduledFor: string | null = null;
  private echoDelay: DelayNode;
  private echoFeedback: GainNode;
  private echoFilter: BiquadFilterNode;
  private echoHp: BiquadFilterNode;
  private echoReturn: GainNode;
  private reverbNode: ConvolverNode;
  private reverbHp: BiquadFilterNode;
  private reverbReturn: GainNode;
  private pendingSwitch: { at: number; to: DeckId; stopOutAt: number; fromDeck: Deck } | null = null;
  private pendingRetire: { at: number; deck: Deck } | null = null;

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

    // Студийная эхо-шина с фильтрацией суб-баса и сочным возвратом
    this.echoDelay = this.ctx.createDelay(3);
    this.echoDelay.delayTime.value = 0.375;
    this.echoFeedback = this.ctx.createGain();
    this.echoFeedback.gain.value = 0.68;
    this.echoFilter = this.ctx.createBiquadFilter();
    this.echoFilter.type = "lowpass";
    this.echoFilter.frequency.value = 4200;
    this.echoHp = this.ctx.createBiquadFilter();
    this.echoHp.type = "highpass";
    this.echoHp.frequency.value = 350;
    this.echoReturn = this.ctx.createGain();
    this.echoReturn.gain.value = 1.15;

    this.echoDelay.connect(this.echoFilter);
    this.echoFilter.connect(this.echoHp);
    this.echoHp.connect(this.echoFeedback);
    this.echoFeedback.connect(this.echoDelay);
    this.echoHp.connect(this.echoReturn);
    this.echoReturn.connect(this.master);

    // Космическая реверберационная шина (Space Reverb Bus)
    this.reverbNode = this.ctx.createConvolver();
    this.reverbNode.buffer = createReverbImpulse(this.ctx, 3.2, 1.9);
    this.reverbHp = this.ctx.createBiquadFilter();
    this.reverbHp.type = "highpass";
    this.reverbHp.frequency.value = 400; // срез суб-баса для прозрачности
    this.reverbReturn = this.ctx.createGain();
    this.reverbReturn.gain.value = 0.95;

    this.reverbNode.connect(this.reverbHp);
    this.reverbHp.connect(this.reverbReturn);
    this.reverbReturn.connect(this.master);

    this.master.connect(this.limiter);
    this.limiter.connect(this.analyser);
    this.analyser.connect(this.ctx.destination);

    this.decks = {
      A: new Deck("A", this.ctx, this.master, this.echoDelay, this.reverbNode),
      B: new Deck("B", this.ctx, this.master, this.echoDelay, this.reverbNode),
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
    if (this.pendingRetire) {
      this.pendingRetire.deck.stop();
      this.pendingRetire = null;
    }
  }

  /**
   * Интеллектуальный расчет длины перехода в музыкальных тактах (1 такт = 4 бита).
   * Базируется на сетке треков, кульминациях (дропах) и музыкальном стиле.
   */
  computePlannedBars(outTrack: Track, target: Track, style: MixStyle): number {
    const s = this.settings;
    if (!s.autoLength) {
      return Math.max(1, Math.round(s.lengthBeats / 4));
    }
    if (style === "cut") return 1;

    const targetA = target.analysis;
    const outA = outTrack.analysis;
    const bpm = outA?.bpm ?? targetA?.bpm ?? 120;
    const barSec = (60 / bpm) * 4;

    // Оцениваем доступный хронометраж в аутро уходящего трека
    const remainingSec = outTrack.duration - (outA?.mixOut ?? (outTrack.duration * 0.80));

    // 1. Проверяем наличие кульминации (дропа) во входящем треке B
    if (targetA?.drops && targetA.drops.length > 0) {
      const earlyDrop = targetA.drops.find((d) => d >= barSec * 4 && d <= 75);
      if (earlyDrop) {
        const dropBars = Math.round(earlyDrop / barSec);
        if (dropBars >= 12 && dropBars <= 20 && remainingSec >= barSec * 16 + 2) return 16;
        if (dropBars >= 6 && dropBars <= 10 && remainingSec >= barSec * 8 + 1) return 8;
      }
    }

    // 2. Золотой стандарт AutoMix: 16 тактов (~28-34 сек) для длинного богатого сведения, иначе 8 тактов
    if (remainingSec >= barSec * 16 + 2 && outTrack.duration >= 90) {
      return 16;
    }
    if (remainingSec >= barSec * 8 + 1 || outTrack.duration >= 45) {
      return 8;
    }
    return 4;
  }

  /** Запуск перехода на nextTrack с выравниванием по тактам, фразам и долям */
  startTransition(next?: Track, styleOverride?: MixStyle): boolean {
    const target = next ?? this.nextTrack;
    const out = this.activeDeck;
    if (!target || !target.buffer || !target.analysis || !out.track || !out.isPlaying || this.transition.active) return false;
    const inn = this.decks[this.active === "A" ? "B" : "A"];
    const s = this.settings;
    const now = this.ctx.currentTime;

    const outA = out.track.analysis;
    const outRate = out.effectiveRate(now);
    const outBpm = (outA?.bpm ?? 120) * outRate;

    let style = styleOverride ?? s.style;
    let rate = 1;

    // --- 1. Гармоничная подгонка темпа под ритмическую сетку (Beatmatching) ---
    // Октавное приведение темпа: 146 BPM и 73 BPM совпадают 1:1 (double/half time)
    if (s.beatmatch && target.analysis?.bpm) {
      let r = outBpm / target.analysis.bpm;
      while (r > 1.414) r /= 2;
      while (r < 0.707) r *= 2;
      // Деликатная подгонка темпа в безопасном диапазоне ±7.5% для сохранения гармонии
      rate = Math.min(1.075, Math.max(0.925, r));
    }

    const beat = 60 / outBpm;
    const bar = beat * 4;

    // --- 2. Интеллектуальный расчет количества тактов и битов ---
    let plannedBars = this.computePlannedBars(out.track, target, style);
    let plannedBeats = plannedBars * 4;

    // --- 3. Выравнивание времени старта (t0) строго по СИЛЬНОЙ ДОЛЕ ТАКТА (Downbeat / бит 1) ---
    const pos = out.position(now);
    const grid = outA?.beatOffset ?? 0;
    const beatTrack = 60 / (outA?.bpm ?? 120);
    const barTrack = beatTrack * 4;

    // Квантование до ближайшего начала следующего такта (с запасом 150мс на планирование Web Audio)
    let kBar = Math.ceil((pos + 0.15 * outRate - grid) / barTrack);
    let startTrack = grid + kBar * barTrack;
    let t0 = out.ctxTimeFor(startTrack);
    if (t0 - now < 0.08) {
      kBar += 1;
      startTrack = grid + kBar * barTrack;
      t0 = out.ctxTimeFor(startTrack);
    }

    // Проверяем, сколько тактов доступно до конца уходящего трека
    const remainingSec = out.track.duration - startTrack;
    const maxFittingBars = Math.floor(remainingSec / (barTrack * outRate));
    if (maxFittingBars < plannedBars) {
      if (maxFittingBars >= 8) plannedBars = 8;
      else if (maxFittingBars >= 4) plannedBars = 4;
      else plannedBars = Math.max(1, maxFittingBars);
      plannedBeats = plannedBars * 4;
    }

    const D = plannedBeats * beat;
    const t1 = t0 + D;

    // --- 4. Подбор точки входа трека B (inOffset) под такт, вокал и кульминацию ---
    const targetA = target.analysis;
    const targetBeat = 60 / targetA.bpm;
    const targetBar = targetBeat * 4;
    const targetGrid = targetA.beatOffset;
    let inOffset = targetA.mixIn;

    if ((style === "mashup" || style === "club" || s.smartCues) && targetA.drops && targetA.drops.length > 0) {
      const leadInSec = D * rate;
      const fittingDrop = targetA.drops.find((d) => d >= leadInSec && d <= 90);
      if (fittingDrop) {
        const rawOffset = fittingDrop - leadInSec;
        inOffset = targetGrid + Math.round((rawOffset - targetGrid) / targetBar) * targetBar;
      }
    }
    // Гарантируем квантование строго по сильной доле такта (Downbeat: Бит 1)
    inOffset = targetGrid + Math.round((inOffset - targetGrid) / targetBar) * targetBar;
    if (inOffset < 0) {
      inOffset = targetGrid + Math.ceil(-targetGrid / targetBar) * targetBar;
    }
    inOffset = Math.max(0, Math.min(target.duration - 5, inOffset));

    // --- 5. Запуск деки B ---
    inn.reset(now);
    inn.start(target, inOffset, t0, rate, this.trimFor(target));
    const gIn = inn.gain.gain;
    const gOut = out.gain.gain;
    gIn.cancelScheduledValues(now);
    gOut.cancelScheduledValues(now);
    gIn.setValueAtTime(0, now);
    gOut.setValueAtTime(gOut.value, now);
    const pre = t0 - 0.002;

    let stopOutAt = t1 + 0.2;

    // --- 6. Настройка DSP-кривых сведения под выбранный стиль ---
    if (style === "cut") {
      gIn.setValueAtTime(0, pre);
      gIn.linearRampToValueAtTime(1, t0 + 0.01);
      gOut.setValueAtTime(1, pre);
      gOut.linearRampToValueAtTime(0, t0 + 0.02);
      stopOutAt = t0 + 0.05;
    } else if (style === "tapestop") {
      // 🛑 ТЕЙП-СТОП / СЛОУ-МО (КОЛЕСО ДИДЖЕЯ):
      const brakeDur = beat * 1.5;
      const brakeStart = t1 - brakeDur;

      // 1. Входящий трек B молчит до дропа, затем ВЗРЫВАЕТСЯ на 100% на сильную долю t1 ("БАЦ!")
      gIn.setValueAtTime(0, pre);
      gIn.setValueAtTime(0, t1 - 0.01);
      gIn.linearRampToValueAtTime(1.0, t1 + 0.02);
      inn.low.gain.setValueAtTime(0, t1);
      inn.mid.gain.setValueAtTime(0, t1);
      inn.hp.frequency.setValueAtTime(20, t1);
      inn.lp.frequency.setValueAtTime(20000, t1);

      // 2. Уходящий трек A играет на полную мощность до начала торможения
      gOut.setValueAtTime(1.0, pre);
      gOut.setValueAtTime(1.0, brakeStart);

      // Замедление винилового диска (колесо диджея)
      if (out.source) {
        const pRate = out.source.playbackRate;
        pRate.cancelScheduledValues(now);
        pRate.setValueAtTime(out.rate, brakeStart);
        pRate.exponentialRampToValueAtTime(0.015, t1 - 0.08);
      }

      // Фильтр плавно закрывается в глухой виниловый спуск:
      out.lp.frequency.cancelScheduledValues(now);
      out.lp.frequency.setValueAtTime(20000, brakeStart);
      out.lp.frequency.exponentialRampToValueAtTime(250, t1 - 0.08);

      // Зазор тишины перед дропом (Pre-Drop Silence 80мс для максимального контраста "БАЦ!"):
      gOut.setValueAtTime(1.0, t1 - 0.12);
      gOut.linearRampToValueAtTime(0, t1 - 0.08);
      gOut.setValueAtTime(0, t1);

      // Эхо-хвост подхватывает торможение:
      const send = out.echoSend.gain;
      send.cancelScheduledValues(now);
      send.setValueAtTime(0, t0);
      send.setValueAtTime(0, brakeStart);
      send.linearRampToValueAtTime(0.65, t1 - 0.10);
      send.linearRampToValueAtTime(0, t1 + 0.1);
      this.echoDelay.delayTime.setValueAtTime(beat * 0.75, now);
      this.echoFeedback.gain.setValueAtTime(0.55, now);

      stopOutAt = t1 + 2.0;
    } else if (style === "stutter") {
      // ⚡ ЗАИКАНИЕ (1/16 BEAT STUTTER ROLL):
      // Входящий трек B готовится:
      gIn.setValueAtTime(0, pre);
      gIn.setValueAtTime(0, t1 - bar);
      gIn.linearRampToValueAtTime(0.30, t1 - beat);
      gIn.setValueAtTime(0.30, t1 - beat * 0.25);
      gIn.linearRampToValueAtTime(0, t1 - beat * 0.1); // затихает перед дропом
      // На сильную долю t1 — ВЗРЫВ!
      gIn.setValueAtTime(0, t1 - 0.005);
      gIn.linearRampToValueAtTime(1.0, t1 + 0.02);

      inn.low.gain.setValueAtTime(-24, t1 - bar);
      inn.low.gain.setValueAtTime(-24, t1 - beat * 0.25);
      inn.low.gain.linearRampToValueAtTime(0, t1);
      inn.mid.gain.setValueAtTime(-8, t1 - bar);
      inn.mid.gain.linearRampToValueAtTime(0, t1);

      // Трек A: ритмичное стробирование громкости
      gOut.setValueAtTime(1.0, pre);
      gOut.setValueAtTime(1.0, t1 - bar);

      // Бит 3: 1/8 пульсации
      const b3 = t1 - beat * 2;
      const eighth = beat / 2;
      for (let step = 0; step < 2; step++) {
        const tStep = b3 + step * eighth;
        gOut.setValueAtTime(1.0, tStep);
        gOut.setValueAtTime(0.05, tStep + eighth * 0.55);
      }

      // Бит 4: 1/16 пулеметный ролл
      const b4 = t1 - beat;
      const sixteenth = beat / 4;
      for (let step = 0; step < 3; step++) {
        const tStep = b4 + step * sixteenth;
        gOut.setValueAtTime(1.0, tStep);
        gOut.setValueAtTime(0.02, tStep + sixteenth * 0.50);
      }

      // Pre-Drop Silence на последней 1/16 доли (зазор тишины перед ударом):
      gOut.setValueAtTime(0, t1 - sixteenth);
      gOut.setValueAtTime(0, t1);

      // Подъем резонансного фильтра во время заикания:
      out.hp.frequency.setValueAtTime(20, t1 - bar);
      out.hp.frequency.exponentialRampToValueAtTime(3200, t1 - sixteenth);
      out.hp.Q.setValueAtTime(0.7, t1 - bar);
      out.hp.Q.linearRampToValueAtTime(3.6, t1 - sixteenth);

      out.low.gain.setValueAtTime(0, t1 - bar);
      out.low.gain.linearRampToValueAtTime(-24, t1 - beat);

      stopOutAt = t1 + 1.5;
    } else if (style === "reverb") {
      // 🌌 КОСМИЧЕСКИЙ РЕВЕРБ:
      const revStart = Math.max(t0 + 0.1, t1 - bar * 2);
      gIn.setValueAtTime(0, pre);
      gIn.setValueAtTime(0, t1 - 0.01);
      gIn.linearRampToValueAtTime(1.0, t1 + 0.02);
      inn.low.gain.setValueAtTime(0, t1);
      inn.mid.gain.setValueAtTime(0, t1);

      // Уходящий трек A: сухой звук затихает, растворяясь в глубоком ревербе
      gOut.setValueAtTime(1.0, pre);
      gOut.setValueAtTime(1.0, revStart);
      gOut.linearRampToValueAtTime(0.12, t1 - beat * 0.5);
      gOut.linearRampToValueAtTime(0, t1);

      out.low.gain.setValueAtTime(0, revStart);
      out.low.gain.linearRampToValueAtTime(-24, t1 - bar);
      out.hp.frequency.setValueAtTime(20, revStart);
      out.hp.frequency.exponentialRampToValueAtTime(600, t1);

      const rSend = out.reverbSend.gain;
      rSend.cancelScheduledValues(now);
      rSend.setValueAtTime(0, t0);
      rSend.setValueAtTime(0, revStart);
      rSend.linearRampToValueAtTime(0.90, t1 - beat * 0.25);
      rSend.setValueAtTime(0.90, t1);
      rSend.linearRampToValueAtTime(0, t1 + 0.3);

      stopOutAt = t1 + 3.2;
    } else if (style === "mashup") {
      // ⚡ НАСТОЯЩИЙ PIONEER AI MASHUP (С ЗАЩИТОЙ ВОКАЛА И BASS SWAP):
      const tMid = t0 + D * 0.5; // Ровно середина перехода (4-й такт из 8 или 8-й из 16)
      const tRiserStart = Math.max(t0 + 0.1, tMid);

      // 1. Входящий трек B:
      // В первой половине (t0 -> tMid) играет подложкой с плавным нарастанием до 0.70
      gIn.setValueAtTime(0, pre);
      gIn.linearRampToValueAtTime(0.70, tMid);
      // Во второй половине (tMid -> t1) выходит на полную мощность 1.00
      gIn.linearRampToValueAtTime(1.0, t1);

      // 2. Вокальная защита (Vocal Pocket Ducking):
      // В первой половине ducking средних частот (-6 dB на 1.2 кГц), чтобы вокал трека A звучал кристально четко!
      // На экваторе tMid вокал трека B плавно открывается до 0 dB
      inn.mid.gain.setValueAtTime(-6, t0);
      inn.mid.gain.setValueAtTime(-6, tMid - beat * 0.5);
      inn.mid.gain.linearRampToValueAtTime(0, tMid);

      // 3. Обмен басом (Bass Handoff):
      // Бас трека B срезан (-24 dB) в первой половине — никакого гула и каши в саб-басе!
      // Ровно на сильную долю середины (tMid) бас трека B взрывается на 0 dB ("БАЦ!")
      inn.low.gain.setValueAtTime(-24, t0);
      inn.low.gain.setValueAtTime(-24, tMid - beat * 0.5);
      inn.low.gain.linearRampToValueAtTime(0, tMid);

      // 4. Уходящий трек A:
      // В первой половине играет на 100%, плавно снижаясь до 0.85 к экватору
      gOut.setValueAtTime(1.0, pre);
      gOut.setValueAtTime(1.0, t0);
      gOut.linearRampToValueAtTime(0.85, tMid);
      // Во второй половине плавно растворяется в ноль (tMid -> t1)
      gOut.linearRampToValueAtTime(0, t1);

      // Бас трека A уходит ровно на сильной доле tMid (Bass Swap):
      out.low.gain.setValueAtTime(0, t0);
      out.low.gain.setValueAtTime(0, tMid - beat * 0.5);
      out.low.gain.linearRampToValueAtTime(-24, tMid);

      // 5. Резонансный High-Pass Riser на треке A (подъем фильтра во второй половине):
      if (s.riserEffect) {
        out.hp.frequency.setValueAtTime(20, t0);
        out.hp.frequency.setValueAtTime(20, tRiserStart);
        out.hp.frequency.exponentialRampToValueAtTime(2400, t1);
        out.hp.Q.setValueAtTime(0.7, t0);
        out.hp.Q.setValueAtTime(0.7, tRiserStart);
        out.hp.Q.linearRampToValueAtTime(2.4, t1);
      }

      // 6. Студийный дилей и реверберация (хвост перетекания):
      const sendStart = Math.max(t0 + 0.1, t1 - bar * 2);
      const send = out.echoSend.gain;
      send.cancelScheduledValues(now);
      send.setValueAtTime(0, t0);
      send.setValueAtTime(0, sendStart);
      send.linearRampToValueAtTime(0.65, t1);
      send.linearRampToValueAtTime(0, t1 + 0.3);
      this.echoDelay.delayTime.setValueAtTime(beat * 0.75, now);
      this.echoFeedback.gain.setValueAtTime(0.60, now);

      stopOutAt = t1 + 2.5;
    } else if (style === "club") {
      // Клубный режим (Club Bass-Swap): чистый кроссфейд с обменом басами на сильной доле такта
      const tMid = t0 + D * 0.5;
      gIn.setValueAtTime(0, pre);
      gIn.setValueCurveAtTime(equalPowerIn, t0, D);
      gOut.setValueAtTime(1, pre);
      gOut.setValueCurveAtTime(equalPowerOut, t0, D);

      if (s.eqSwap) {
        const lo = out.low.gain;
        const li = inn.low.gain;
        lo.cancelScheduledValues(now);
        li.cancelScheduledValues(now);
        li.setValueAtTime(-24, t0);
        li.setValueAtTime(-24, tMid - beat * 0.25);
        li.linearRampToValueAtTime(0, tMid);

        lo.setValueAtTime(0, t0);
        lo.setValueAtTime(0, tMid - beat * 0.25);
        lo.linearRampToValueAtTime(-24, tMid);
      }
      stopOutAt = t1 + 1.2;
    } else if (style === "smooth") {
      // 🎵 Spotify Premium AutoMix (Continuous Harmonic Flow):
      const tMid = t0 + D * 0.5;

      gIn.setValueAtTime(0, pre);
      gIn.setValueCurveAtTime(equalPowerIn, t0, D);
      gOut.setValueAtTime(1, pre);
      gOut.setValueCurveAtTime(equalPowerOut, t0, D);

      if (s.eqSwap) {
        const lo = out.low.gain;
        const li = inn.low.gain;
        lo.cancelScheduledValues(now);
        li.cancelScheduledValues(now);

        lo.setValueAtTime(0, t0);
        lo.setValueAtTime(0, tMid - beat * 0.5);
        lo.linearRampToValueAtTime(-24, tMid);

        li.setValueAtTime(-20, t0);
        li.setValueAtTime(-20, tMid - beat * 0.5);
        li.linearRampToValueAtTime(0, tMid);
      }

      if (s.riserEffect) {
        const riserStart = Math.max(t0 + 0.1, tMid);
        out.hp.frequency.setValueAtTime(20, t0);
        out.hp.frequency.setValueAtTime(20, riserStart);
        out.hp.frequency.exponentialRampToValueAtTime(1600, t1);
        out.hp.Q.setValueAtTime(0.7, t0);
        out.hp.Q.setValueAtTime(0.7, riserStart);
        out.hp.Q.linearRampToValueAtTime(1.8, t1);
      }

      const send = out.echoSend.gain;
      send.cancelScheduledValues(now);
      send.setValueAtTime(0, t0);
      const sendStart = Math.max(t0 + 0.1, t1 - bar);
      send.setValueAtTime(0, sendStart);
      send.linearRampToValueAtTime(0.50, t1);
      send.linearRampToValueAtTime(0, t1 + 0.2);
      this.echoDelay.delayTime.setValueAtTime(beat * 0.75, now);
      this.echoFeedback.gain.setValueAtTime(0.50, now);

      stopOutAt = t1 + 2.0;
    } else if (style === "echo") {
      // Cosmic Echo Out
      const tMid = t0 + D * 0.5;
      this.echoDelay.delayTime.setValueAtTime(beat * 0.75, now);
      this.echoFeedback.gain.setValueAtTime(0.65, now);
      gIn.setValueAtTime(0, pre);
      gIn.setValueCurveAtTime(equalPowerIn, t0, D);
      gOut.setValueAtTime(1, pre);
      gOut.setValueAtTime(1, tMid);
      gOut.linearRampToValueAtTime(0, t1);
      const send = out.echoSend.gain;
      send.cancelScheduledValues(now);
      send.setValueAtTime(0, t0);
      send.setValueAtTime(0, tMid);
      send.linearRampToValueAtTime(0.80, t1);
      send.linearRampToValueAtTime(0, t1 + 0.3);
      out.hp.frequency.setValueAtTime(20, tMid);
      out.hp.frequency.exponentialRampToValueAtTime(2000, t1);
      stopOutAt = t1 + 2.8;
    } else {
      gIn.setValueAtTime(0, pre);
      gIn.setValueCurveAtTime(equalPowerIn, t0, D);
      gOut.setValueAtTime(1, pre);
      gOut.setValueCurveAtTime(equalPowerOut, t0, D);
      stopOutAt = t1 + 0.5;
    }

    // --- 7. Плавный возврат темпа после перехода ---
    if (Math.abs(rate - 1) > 0.001) {
      inn.scheduleGlide(t1 + 0.1, t1 + 0.1 + Math.max(8, D), 1);
    }

    out.stop(stopOutAt);
    this.pendingSwitch = { at: t1, to: inn.id, stopOutAt, fromDeck: out };
    const styleLabels: Record<string, string> = {
      mashup: "⚡ AI Мэшап Drop Swap",
      smooth: "🌊 Spotify Flow",
      club: "🎛 Клубный Kick-Swap",
      echo: "🌌 Cosmic Echo",
      cut: "✂ Прямой Кат",
    };
    this.transition = {
      active: true,
      fromId: out.track.id,
      toId: target.id,
      progress: 0,
      startedAt: t0,
      duration: D,
      tempoShift: (rate - 1) * 100,
      style,
      plannedBars,
      plannedBeats,
      currentBar: 1,
      currentBeat: 1,
      description: `${styleLabels[style]} (${plannedBars} тактов · ${plannedBeats} бита)`,
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
      const elapsed = Math.max(0, now - tr.startedAt);
      const beatDur = tr.duration / (tr.plannedBeats || 1);
      const totalBeats = Math.floor(elapsed / beatDur);
      tr.currentBar = Math.min(tr.plannedBars, Math.floor(totalBeats / 4) + 1);
      tr.currentBeat = (totalBeats % 4) + 1;

      if (this.pendingSwitch && now >= this.pendingSwitch.at) {
        const retiringDeck = this.pendingSwitch.fromDeck;
        const retireAt = this.pendingSwitch.stopOutAt;
        this.active = this.pendingSwitch.to;
        this.pendingSwitch = null;
        this.pendingRetire = { at: retireAt, deck: retiringDeck };
        this.transition = { ...tr, active: false, progress: 1 };
        this.endedFired = false;
        this.transitionScheduledFor = null;
        // Источник уходящей деки НЕ сбрасывается здесь — хвост дилея (Delay Spillover) продолжает звучать!
        this.emit({ type: "trackChange", track: this.activeDeck.track ?? undefined });
        this.emit({ type: "transitionEnd" });
      }
    }

    // Чистка деки только после полного затухания хвоста эффектов (Spillover)
    if (this.pendingRetire && now >= this.pendingRetire.at) {
      const d = this.pendingRetire.deck;
      d.source = null;
      d.reset(now);
      this.pendingRetire = null;
    }

    if (!tr.active && out.track && out.isPlaying && this.ctx.state === "running") {
      const a = out.track.analysis;
      const pos = out.position(now);
      const beat = a ? 60 / a.bpm : 0.5;
      const bar = beat * 4;

      if (this.nextTrack && this.nextTrack.buffer && this.nextTrack.analysis && this.transitionScheduledFor !== out.track.id) {
        const plannedBars = this.computePlannedBars(out.track, this.nextTrack, this.settings.style);
        const plannedSec = plannedBars * bar;
        // Точка схода: mixOut или крайний рубеж за plannedSec до конца трека
        const latestStart = Math.max(0, out.track.duration - plannedSec - 0.8);
        const mixOut = Math.min(a?.mixOut ?? latestStart, latestStart);

        // Инициируем переход за 0.8 такта до mixOut (или принудительно на рубеже latestStart)
        if (pos >= mixOut - bar * 0.8 || pos >= latestStart) {
          this.startTransition();
        }
      } else if (pos >= out.track.duration - 0.1 && !this.endedFired) {
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
