import {
  bassGainDbAt,
  phaseLabel,
  pitchCentsAt,
  playbackRatesAt,
  volumesAt,
} from "./envelopes";
import { bloomInstrumental, crossfadedLoop, sliceToBuffer } from "./neuralStems";
import type { MashupParams } from "./envelopes";
import { runMixCritic } from "./mixCritic";
import {
  BassEqNode,
  EchoOutNode,
  FilterSweepNode,
  MidSideStemNode,
  ReverbWashNode,
  beatmatchTransport,
  stemFxAt,
  setParam,
} from "../dsp";

export type DeckId = "a" | "b";

export type DeckState = {
  name: string;
  buffer: AudioBuffer | null;
  duration: number;
  bpm: number;
};

export type EngineSnapshot = {
  playing: boolean;
  progress: number;
  phase: string;
  volA: number;
  volB: number;
  bassA: number;
  bassB: number;
  rateA: number;
  rateB: number;
  pitchB: number;
  instrA: number;
  instrB: number;
  vocalB: number;
  hpfA: number;
  lpfB: number;
  echoA: number;
  reverbA: number;
  stutterA: number;
  displayElapsed: number;
  displayDuration: number;
  displayDeck: DeckId;
  processingNote?: string;
};

type SourceChain = {
  source: AudioBufferSourceNode;
  stem: MidSideStemNode;
  eq: BassEqNode;
  filters: FilterSweepNode;
  echo: EchoOutNode;
  reverb: ReverbWashNode;
  gain: GainNode;
  /** Baked slices start at 0; full-buffer playback uses cue offset. */
  startOffset: number;
};

export type AudioMeter = {
  /** 0…1 low-band energy (kick / bass). */
  bass: number;
  /** 0…1 mid energy. */
  mid: number;
  /** 0…1 high energy. */
  treble: number;
  /** 0…1 broadband level. */
  level: number;
};

export class AutomixEngine {
  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
  private outputGain = 0.8;
  private analyser: AnalyserNode | null = null;
  private analyserBuf: Uint8Array<ArrayBuffer> | null = null;
  private decks: Record<DeckId, DeckState> = {
    a: { name: "Track A", buffer: null, duration: 0, bpm: 120 },
    b: { name: "Track B", buffer: null, duration: 0, bpm: 124 },
  };
  private chainA: SourceChain | null = null;
  private chainB: SourceChain | null = null;
  private params: MashupParams;
  private startedAt = 0;
  private playing = false;
  private raf = 0;
  private onTick: ((s: EngineSnapshot) => void) | null = null;
  private handoffSnapped = false;
  private processingNote = "";

  constructor(params: MashupParams) {
    this.params = { ...params, dsp: { ...params.dsp } };
  }

  setParams(params: MashupParams) {
    this.params = {
      ...params,
      dsp: { ...params.dsp, decisions: [...(params.dsp?.decisions ?? [])] },
    };
  }

  getParams() {
    return {
      ...this.params,
      dsp: { ...this.params.dsp, decisions: [...this.params.dsp.decisions] },
    };
  }

  getDeck(id: DeckId) {
    return this.decks[id];
  }

  onUpdate(cb: (s: EngineSnapshot) => void) {
    this.onTick = cb;
  }

  async ensureContext() {
    if (!this.ctx) {
      this.ctx = new AudioContext();
      this.master = this.ctx.createGain();
      this.master.gain.value = this.outputGain;
      this.analyser = this.ctx.createAnalyser();
      this.analyser.fftSize = 512;
      this.analyser.smoothingTimeConstant = 0.62;
      this.analyserBuf = new Uint8Array(
        this.analyser.frequencyBinCount
      ) as Uint8Array<ArrayBuffer>;
      // Parallel tap — never interrupt the audible path.
      this.master.connect(this.ctx.destination);
      this.master.connect(this.analyser);
    }
    if (this.ctx.state === "suspended") await this.ctx.resume();
    return this.ctx;
  }

  /** Output loudness, 0–1. Applies immediately once the context exists. */
  setOutputVolume(value: number) {
    this.outputGain = Math.min(1, Math.max(0, value));
    if (this.master && this.ctx) {
      this.master.gain.setTargetAtTime(this.outputGain, this.ctx.currentTime, 0.03);
    }
  }

  /** Live spectrum bands for UI (ambient / pulse). Safe when silent. */
  getMeter(): AudioMeter {
    const empty = { bass: 0, mid: 0, treble: 0, level: 0 };
    if (!this.analyser || !this.analyserBuf || !this.playing) return empty;
    this.analyser.getByteFrequencyData(this.analyserBuf);
    const buf = this.analyserBuf;
    const n = buf.length;
    if (n < 8) return empty;
    const band = (from: number, to: number) => {
      let sum = 0;
      let c = 0;
      const a = Math.max(0, Math.min(n, from | 0));
      const b = Math.max(a + 1, Math.min(n, to | 0));
      for (let i = a; i < b; i++) {
        sum += buf[i]!;
        c++;
      }
      return c ? sum / (c * 255) : 0;
    };
    // ~0–180 Hz / mids / highs at 44.1k + fft 512
    const bass = Math.min(1, band(1, 6) * 1.55);
    const mid = Math.min(1, band(6, 40) * 1.25);
    const treble = Math.min(1, band(40, n) * 1.35);
    const level = Math.min(1, bass * 0.45 + mid * 0.35 + treble * 0.2);
    return { bass, mid, treble, level };
  }

  /** BPM of the deck currently driving display (A during solo). */
  getBpm(id: DeckId = "a"): number {
    return this.decks[id].bpm || 120;
  }

  async loadFile(id: DeckId, file: File) {
    const ctx = await this.ensureContext();
    const data = await file.arrayBuffer();
    const buffer = await ctx.decodeAudioData(data.slice(0));
    this.decks[id] = {
      name: file.name.replace(/\.[^.]+$/, ""),
      buffer,
      duration: buffer.duration,
      bpm: this.decks[id].bpm,
    };
    return this.decks[id];
  }

  async loadArrayBuffer(id: DeckId, data: ArrayBuffer, name: string) {
    const ctx = await this.ensureContext();
    const buffer = await ctx.decodeAudioData(data.slice(0));
    this.decks[id] = {
      name: name.replace(/\.[^.]+$/, ""),
      buffer,
      duration: buffer.duration,
      bpm: this.decks[id].bpm,
    };
    return this.decks[id];
  }

  /** Swap deck buffers after a successful mashup handoff (B becomes A). */
  promoteBToA() {
    this.decks.a = { ...this.decks.b };
    this.decks.b = { name: "Track B", buffer: null, duration: 0, bpm: 124 };
  }

  setBpm(id: DeckId, bpm: number) {
    this.decks[id].bpm = Math.max(40, Math.min(220, bpm));
  }

  stop() {
    this.playing = false;
    this.soloUntilResolve?.(false);
    this.soloUntilResolve = null;
    this.mashupResolve?.(false);
    this.mashupResolve = null;
    cancelAnimationFrame(this.raf);
    this.teardownChain(this.chainA);
    this.teardownChain(this.chainB);
    this.chainA = null;
    this.chainB = null;
    this.handoffSnapped = false;
    this.soloEndedAt = null;
    this.neuralActive = false;
    this.emit(0);
  }

  clearNeuralMashup() {
    this.neuralTake = null;
    this.neuralActive = false;
  }

  async decodeAudio(data: ArrayBuffer): Promise<AudioBuffer> {
    const ctx = await this.ensureContext();
    return ctx.decodeAudioData(data.slice(0));
  }

  /**
   * Arm the lab HTDemucs AutoMix.
   * The song that is ending plays its instrumental. The next song plays its vocal,
   * then opens into the dry file at LAND. Duet is both vocals trading.
   * The older full-mix path is unchanged when this returns false.
   */
  armNeuralMashup(input: {
    duet: boolean;
    cueA: number;
    cueB: number;
    blendSec: number;
    handoffAt: number;
    bedA: AudioBuffer;
    bedStartSec: number;
    leadB: AudioBuffer;
    leadStartSec: number;
    /** One bar. The vocal becomes the full song across this, arriving on the downbeat. */
    landFadeSec?: number;
  }): boolean {
    const deckB = this.decks.b.buffer;
    const ctx = this.ctx;
    if (!deckB || !ctx) {
      this.neuralTake = null;
      return false;
    }
    const offsetA = input.cueA - input.bedStartSec;
    const offsetB = input.cueB - input.leadStartSec;
    if (
      offsetA < -0.05 ||
      offsetA > input.bedA.duration - 0.8 ||
      offsetB < -0.05 ||
      offsetB > input.leadB.duration - 0.8
    ) {
      this.neuralTake = null;
      return false;
    }
    const blend = Math.max(1, input.blendSec);
    const landAt = Math.max(0, offsetB) + blend * Math.min(0.98, Math.max(0.35, input.handoffAt));
    const dry = sliceToBuffer(ctx, deckB, input.leadStartSec, input.leadB.length, input.leadB.sampleRate);
    const bloomed = bloomInstrumental(
      ctx,
      input.leadB,
      dry,
      landAt,
      input.landFadeSec ?? 1.1
    );
    this.neuralTake = {
      bufferA: input.bedA,
      bufferB: bloomed,
      offsetA: Math.max(0, offsetA),
      offsetB: Math.max(0, offsetB),
    };
    return true;
  }

  private soloUntilResolve: ((ok: boolean) => void) | null = null;
  private mashupResolve: ((ok: boolean) => void) | null = null;
  private soloStartSec = 0;
  private soloUntilSec = 0;
  private soloRate = 1;
  /** Position captured when solo stops, so the next handoff does not rewind to the start. */
  private soloEndedAt: number | null = null;

  /** Update solo end target while playing (e.g. after plan is ready). */
  setSoloUntil(untilSec: number) {
    this.soloUntilSec = Math.max(this.soloStartSec + 0.2, untilSec);
  }

  /**
   * Keep the same solo source running past the cue while the next track
   * or the plan is still loading. Avoids a stop/start jump.
   */
  resumeSoloUntil(untilSec: number): Promise<boolean> {
    const chain = this.chainA ?? this.chainB;
    const ctx = this.ctx;
    if (!chain || !ctx) return Promise.resolve(false);
    const pos = this.soloEndedAt ?? this.getSoloPosition();
    const rate = this.soloRate || 1;
    this.startedAt = performance.now() - ((pos - this.soloStartSec) / rate) * 1000;
    this.soloUntilSec = Math.max(pos + 0.35, untilSec);
    this.soloEndedAt = null;
    this.playing = true;
    const deckId: DeckId = this.chainA ? "a" : "b";
    const deck = this.decks[deckId];
    return new Promise<boolean>((resolve) => {
      this.soloUntilResolve = resolve;
      const tick = () => {
        if (!this.playing) {
          const done = this.soloUntilResolve;
          this.soloUntilResolve = null;
          done?.(false);
          return;
        }
        if (ctx.state === "suspended") void ctx.resume().catch(() => undefined);
        const elapsed = (performance.now() - this.startedAt) / 1000;
        const here = this.soloStartSec + elapsed * rate;
        this.onTick?.({
          playing: true,
          progress: 0,
          phase: "PLAY",
          volA: deckId === "a" ? 1 : 0,
          volB: deckId === "b" ? 1 : 0,
          bassA: 0,
          bassB: 0,
          rateA: 1,
          rateB: 1,
          pitchB: 0,
          instrA: 0,
          instrB: 0,
          vocalB: 0,
          hpfA: 0,
          lpfB: 0,
          echoA: 0,
          reverbA: 0,
          stutterA: 0,
          displayElapsed: Math.min(deck.duration, here),
          displayDuration: deck.duration,
          displayDeck: deckId,
        });
        if (here >= this.soloUntilSec) {
          this.soloEndedAt = Math.min(deck.duration, this.soloUntilSec);
          this.playing = false;
          cancelAnimationFrame(this.raf);
          const done = this.soloUntilResolve;
          this.soloUntilResolve = null;
          done?.(true);
          return;
        }
        this.raf = requestAnimationFrame(tick);
      };
      this.raf = requestAnimationFrame(tick);
    });
  }

  /** Current track position during solo play, or the position where solo stopped. */
  getSoloPosition(): number {
    if (this.playing) {
      const elapsed = (performance.now() - this.startedAt) / 1000;
      return this.soloStartSec + elapsed * this.soloRate;
    }
    return this.soloEndedAt ?? this.soloStartSec;
  }

  /** True while a solo-until promise is outstanding. */
  isSoloPlaying(): boolean {
    return this.playing && this.soloUntilResolve != null;
  }

  /**
   * Interrupt solo without finishing the until-target.
   * Resolves the pending playSoloUntil promise with `false`.
   */
  interruptSolo() {
    if (!this.soloUntilResolve) {
      this.stop();
      return;
    }
    this.soloEndedAt = this.getSoloPosition();
    this.playing = false;
    cancelAnimationFrame(this.raf);
    this.teardownChain(this.chainA);
    this.teardownChain(this.chainB);
    this.chainA = null;
    this.chainB = null;
    const done = this.soloUntilResolve;
    this.soloUntilResolve = null;
    done(false);
  }

  /**
   * Vocal Safe / Bass Surgeon on the recipe about to play.
   * No-op when cue vocal levels were not stored (manual knob sessions).
   */
  private enforceCritic() {
    const dsp = this.params.dsp;
    if (dsp.guardVocalOut == null || dsp.guardVocalIn == null) return;
    runMixCritic({
      params: this.params,
      vocalOut: dsp.guardVocalOut,
      vocalIn: dsp.guardVocalIn,
      bpm: this.params.targetBPM > 30 ? this.params.targetBPM : 120,
      transitionType: "eqBlend",
      harmonicOk: true,
      beatmatched: true,
    });
  }

  /**
   * Full auto path: critic gates, then bake stems, then play.
   * Call after setParams(plan.params).
   */
  async playAutoMashup(onStatus?: (msg: string) => void): Promise<boolean> {
    const a = this.decks.a.buffer;
    const b = this.decks.b.buffer;
    if (!a || !b) throw new Error("Загрузи оба трека");
    this.enforceCritic();
    const ctx = await this.ensureContext();

    const p = this.params;
    const dsp = p.dsp;
    const cueA = Math.min(Math.max(0, p.cueASec), Math.max(0, a.duration - 1));
    const cueB = Math.min(Math.max(0, p.cueBSec), Math.max(0, b.duration - 1));
    // Adaptive Duet + AutoMix: never shorter than 4s (no blink).
    const blendFloor = 4;
    const remainA = Math.max(1.6, a.duration - cueA - 0.2);
    const blend = Math.max(
      Math.min(blendFloor, remainA),
      Math.min(48, p.blendDurationSec, remainA)
    );

    const modeLabel = dsp.mashupMode || "mashup";
    onStatus?.(`Сведение · ${modeLabel}`);
    this.processingNote = modeLabel;

    // Live path stays on the original files. Offline stem bake and WSOLA
    // ran after stop(), so the song froze and came back thinner. Tempo is a
    // small playbackRate; key is detune. No second render of the audio.
    let bufA = a;
    let bufB = b;
    let offsetA = cueA;
    let offsetB = cueB;
    let liveInstrScale = 1;
    this.pitchLockedA = false;
    this.pitchLockedB = false;
    const take = this.neuralTake;
    this.neuralTake = null;
    this.neuralActive = false;
    if (
      take &&
      take.offsetA < take.bufferA.duration - 0.4 &&
      take.offsetB < take.bufferB.duration - 0.4
    ) {
      bufA = take.bufferA;
      bufB = take.bufferB;
      offsetA = take.offsetA;
      offsetB = take.offsetB;
      this.neuralActive = true;
      liveInstrScale = 0;
      const bpm = p.targetBPM > 30 ? p.targetBPM : this.decks.a.bpm > 30 ? this.decks.a.bpm : 120;
      const bars = Math.max(2, dsp.loopBarsA || 0);
      const loopSec = bars * 4 * (60 / bpm);
      const room = bufA.duration - offsetA;
      if (room > loopSec + 0.2 && loopSec > 0.45) {
        const barSec = 4 * (60 / bpm);
        const holdSec = Math.max(loopSec, p.handoffAt * blend - barSec);
        bufA = crossfadedLoop(ctx, bufA, offsetA, loopSec, holdSec, barSec);
        offsetA = 0;
      }
    }

    const neuralLabel =
      dsp.mashupMode === "oneBarDuet"
        ? "HTDemucs · баттл вокалов"
        : "HTDemucs · инстр A + вокал B · луп";
    onStatus?.(this.neuralActive ? `Сведение · ${neuralLabel}` : "Сведение · полный микс");
    this.processingNote = this.neuralActive ? neuralLabel : "полный микс";

    const musical = (rate: number) => Math.min(1.04, Math.max(0.96, rate || 1));
    const previousA = this.chainA;
    const previousB = this.chainB;
    this.chainA = null;
    this.chainB = null;
    this.playing = false;
    cancelAnimationFrame(this.raf);

    this.chainA = this.makeChain(bufA, musical(p.rateA), offsetA);
    this.chainB = this.makeChain(bufB, musical(p.rateB), offsetB);

    this.liveInstrScale = liveInstrScale;

    const now = ctx.currentTime + 0.05;
    this.startedAt = performance.now();
    this.playing = true;
    this.handoffSnapped = false;

    const bpm =
      p.targetBPM > 30
        ? p.targetBPM
        : this.decks.a.bpm > 30
          ? this.decks.a.bpm
          : 120;
    this.chainA.echo.setTempo(bpm, now, true);
    this.chainB.echo.setTempo(this.decks.b.bpm || bpm, now, true);
    this.applyPhraseLoop(this.chainA);

    this.applyEnvelope(0, now, true);

    this.chainA.source.start(now, this.chainA.startOffset);
    this.chainB.source.start(now, this.chainB.startOffset);
    for (const old of [previousA, previousB]) {
      if (!old) continue;
      try {
        old.gain.gain.cancelScheduledValues(now);
        old.gain.gain.setValueAtTime(old.gain.gain.value, now);
        old.gain.gain.linearRampToValueAtTime(0, now + 0.08);
        old.source.stop(now + 0.1);
      } catch {
        /* already ended */
      }
      window.setTimeout(() => this.teardownChain(old), 400);
    }

    // Keep B alive long enough for waveRadio to hand off into solo without a
    // silent gap (finishMashupLog / promote used to outrun a 0.8s tail).
    const stopAt = now + blend + 0.8;
    try {
      this.chainA.source.stop(stopAt);
      this.chainB.source.stop(now + blend + 12);
    } catch {
      /* ignore */
    }

    return new Promise<boolean>((resolve) => {
      this.mashupResolve = resolve;
      const tick = () => {
        // stop()/interrupt already resolved — never leave the promise hanging.
        if (!this.playing) {
          if (this.mashupResolve) {
            const done = this.mashupResolve;
            this.mashupResolve = null;
            done(false);
          }
          return;
        }
        const elapsed = (performance.now() - this.startedAt) / 1000;
        const progress = Math.min(1, elapsed / blend);
        this.applyEnvelope(progress, ctx.currentTime, false);
        this.emit(progress);
        if (progress >= 1) {
          this.playing = false;
          this.processingNote = "";
          this.emit(1);
          const done = this.mashupResolve;
          this.mashupResolve = null;
          done?.(true);
          return;
        }
        this.raf = requestAnimationFrame(tick);
      };
      this.raf = requestAnimationFrame(tick);
    });
  }

  /** Manual play without re-baking (uses current params + live DSP only). */
  async playMashup() {
    return this.playAutoMashup();
  }

  /**
   * Apple Crossfade. Equal-power volumes only, fixed overlap, rates locked at 1.
   * No stem carve, echo, or HPF — those stay on the AutoMix path.
   */
  async playCrossfade(
    bufferA: AudioBuffer,
    bufferB: AudioBuffer,
    cueA: number,
    cueB: number,
    seconds: number,
    onStatus?: (msg: string) => void
  ): Promise<boolean> {
    if (!bufferA || !bufferB) throw new Error("Загрузи оба трека");
    const ctx = await this.ensureContext();
    this.stop();

    const blend = Math.min(12, Math.max(1, seconds));
    const startA = Math.min(Math.max(0, cueA), Math.max(0, bufferA.duration - 0.2));
    const startB = Math.min(Math.max(0, cueB), Math.max(0, bufferB.duration - 0.2));
    onStatus?.(`Mixing · Crossfade ${blend.toFixed(0)}s`);
    this.processingNote = "equal-power crossfade";

    this.chainA = this.makeChain(bufferA, 1, startA);
    this.chainB = this.makeChain(bufferB, 1, startB);
    this.liveInstrScale = 1;

    const now = ctx.currentTime + 0.05;
    this.startedAt = performance.now();
    this.playing = true;
    this.handoffSnapped = false;

    for (const chain of [this.chainA, this.chainB]) {
      chain.source.playbackRate.value = 1;
      try {
        chain.source.detune.setValueAtTime(0, now);
      } catch {
        /* detune optional */
      }
      chain.stem.setDry(now, true);
      chain.eq.setBassGainDb(0, now, true);
      chain.filters.setOpen(now, true);
      chain.echo.bypass(now, true);
      chain.reverb.bypass(now, true);
    }

    const eqPower = (p: number) => {
      const t = Math.min(1, Math.max(0, p));
      return {
        volA: Math.cos(t * Math.PI * 0.5),
        volB: Math.sin(t * Math.PI * 0.5),
      };
    };

    const paint = (progress: number) => {
      const { volA, volB } = eqPower(progress);
      const elapsed = (performance.now() - this.startedAt) / 1000;
      const displayDeck: DeckId = progress >= 0.5 ? "b" : "a";
      const displayElapsed = displayDeck === "b" ? startB + elapsed : startA + elapsed;
      const displayDuration = displayDeck === "b" ? bufferB.duration : bufferA.duration;
      this.onTick?.({
        playing: this.playing,
        progress,
        phase: "CROSSFADE",
        volA,
        volB,
        bassA: 0,
        bassB: 0,
        rateA: 1,
        rateB: 1,
        pitchB: 0,
        instrA: 0,
        instrB: 0,
        vocalB: 0,
        hpfA: 0,
        lpfB: 0,
        echoA: 0,
        reverbA: 0,
        stutterA: 0,
        displayElapsed: Math.min(displayDuration, Math.max(0, displayElapsed)),
        displayDuration: displayDuration || 1,
        displayDeck,
        processingNote: "equal-power crossfade",
      });
    };

    const gains = eqPower(0);
    this.chainA.gain.gain.setValueAtTime(gains.volA, now);
    this.chainB.gain.gain.setValueAtTime(gains.volB, now);
    this.chainA.source.start(now, this.chainA.startOffset);
    this.chainB.source.start(now, this.chainB.startOffset);
    try {
      this.chainA.source.stop(now + blend + 0.3);
      // Tail B past the crossfade so the solo handoff can start without silence.
      this.chainB.source.stop(now + blend + 12);
    } catch {
      /* ignore */
    }

    return new Promise<boolean>((resolve) => {
      this.mashupResolve = resolve;
      const tick = () => {
        if (!this.playing || !this.chainA || !this.chainB) return;
        const elapsed = (performance.now() - this.startedAt) / 1000;
        const progress = Math.min(1, elapsed / blend);
        const { volA, volB } = eqPower(progress);
        const at = ctx.currentTime;
        this.chainA.gain.gain.setValueAtTime(volA, at);
        this.chainB.gain.gain.setValueAtTime(volB, at);
        paint(progress);
        if (progress >= 1) {
          this.playing = false;
          this.processingNote = "";
          paint(1);
          const done = this.mashupResolve;
          this.mashupResolve = null;
          done?.(true);
          return;
        }
        this.raf = requestAnimationFrame(tick);
      };
      this.raf = requestAnimationFrame(tick);
    });
  }

  private liveInstrScale = 1;
  /** HTDemucs buffers for the next mashup. Consumed by playAutoMashup. */
  private neuralTake: {
    bufferA: AudioBuffer;
    bufferB: AudioBuffer;
    offsetA: number;
    offsetB: number;
  } | null = null;
  /** Live Mid/Side stays off while these buffers are already vocal / instrumental. */
  private neuralActive = false;
  /** Blend was offline time-stretched; playbackRate stays 1, Camelot is detune-only. */
  private pitchLockedA = false;
  private pitchLockedB = false;

  /**
   * Play one deck from `fromSec` until `untilSec` (track position).
   * Resolves true when until reached, false if stopped early.
   */
  async playSoloUntil(
    id: DeckId,
    fromSec: number,
    untilSec: number,
    rate = 1
  ): Promise<boolean> {
    const deck = this.decks[id];
    if (!deck.buffer) throw new Error("Нет трека");
    const ctx = await this.ensureContext();
    this.stop();
    const start = Math.max(0, Math.min(fromSec, deck.duration - 0.05));
    const until = Math.max(start + 0.2, Math.min(untilSec, deck.duration - 0.05));
    const chain = this.makeChain(deck.buffer, rate, start);
    if (id === "a") this.chainA = chain;
    else this.chainB = chain;
    chain.gain.gain.value = 1;
    chain.eq.setBassGainDb(0, ctx.currentTime, true);
    chain.stem.setDry(ctx.currentTime, true);
    chain.filters.setOpen(ctx.currentTime, true);
    chain.echo.bypass(ctx.currentTime, true);
    chain.reverb.bypass(ctx.currentTime, true);
    const now = ctx.currentTime + 0.05;
    this.startedAt = performance.now();
    this.soloStartSec = start;
    this.soloUntilSec = until;
    this.soloRate = rate;
    this.soloEndedAt = null;
    this.playing = true;
    this.processingNote = "";
    this.handoffSnapped = id === "b";
    chain.source.start(now, chain.startOffset);
    // If the buffer ends before untilSec, keep the wall-clock tick alive —
    // but never leave the Promise hanging if something clears `playing`.
    try {
      chain.source.onended = () => {
        /* wall-clock tick still owns resolve */
      };
    } catch {
      /* ignore */
    }

    return new Promise<boolean>((resolve) => {
      this.soloUntilResolve = resolve;
      const tick = () => {
        if (!this.playing) {
          // Defensive: stop()/interrupt should have resolved already.
          if (this.soloUntilResolve) {
            const done = this.soloUntilResolve;
            this.soloUntilResolve = null;
            done(false);
          }
          return;
        }
        // Tab background / autoplay policy can suspend the context mid-song.
        if (ctx.state === "suspended") {
          void ctx.resume().catch(() => undefined);
        }
        const elapsed = (performance.now() - this.startedAt) / 1000;
        const pos = start + elapsed * rate;
        this.onTick?.({
          playing: true,
          progress: 0,
          phase: "PLAY",
          volA: id === "a" ? 1 : 0,
          volB: id === "b" ? 1 : 0,
          bassA: 0,
          bassB: 0,
          rateA: this.params.rateA,
          rateB: this.params.rateB,
          pitchB: 0,
          instrA: 0,
          instrB: 0,
          vocalB: 0,
          hpfA: 0,
          lpfB: 0,
          echoA: 0,
          reverbA: 0,
          stutterA: 0,
          displayElapsed: Math.min(deck.duration, pos),
          displayDuration: deck.duration,
          displayDeck: id,
        });
        if (pos >= this.soloUntilSec) {
          this.soloEndedAt = Math.min(deck.duration, this.soloUntilSec);
          this.playing = false;
          cancelAnimationFrame(this.raf);
          const done = this.soloUntilResolve;
          this.soloUntilResolve = null;
          done?.(true);
          return;
        }
        this.raf = requestAnimationFrame(tick);
      };
      this.raf = requestAnimationFrame(tick);
    });
  }

  async playSolo(id: DeckId, fromSec?: number) {
    const deck = this.decks[id];
    if (!deck.buffer) throw new Error("Нет трека");
    const until = Math.max(0.5, deck.duration - 0.05);
    const cue = fromSec ?? (id === "a" ? this.params.cueASec : this.params.cueBSec);
    return this.playSoloUntil(id, cue, until, id === "a" ? this.params.rateA : this.params.rateB);
  }

  private makeChain(buffer: AudioBuffer, rate: number, startOffset: number): SourceChain {
    const ctx = this.ctx!;
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.playbackRate.value = rate;

    const stem = new MidSideStemNode(ctx);
    const eq = new BassEqNode(ctx);
    const filters = new FilterSweepNode(ctx);
    const echo = new EchoOutNode(ctx);
    const reverb = new ReverbWashNode(ctx);
    const gain = ctx.createGain();
    gain.gain.value = 0;

    // player → stem → EQ → filters → echo → reverb → gain (mirrors DualDeck FX order)
    source.connect(stem.input);
    stem.output.connect(eq.input);
    eq.output.connect(filters.input);
    filters.output.connect(echo.input);
    echo.output.connect(reverb.input);
    reverb.output.connect(gain);
    gain.connect(this.master!);

    return { source, stem, eq, filters, echo, reverb, gain, startOffset };
  }

  /**
  /**
   * The neural bed already repeats its phrase with a crossfade.
   * A raw BufferSource loop clicks, so this stays linear.
   */
  private applyPhraseLoop(chain: SourceChain) {
    chain.source.loop = false;
  }

  /** 1/8 gate. Floor stays above silence so the chop does not click. */
  private phraseGate(amount: number): number {
    const bpm = this.params.targetBPM > 30 ? this.params.targetBPM : 120;
    const eighth = 60 / bpm / 2;
    const elapsed = (performance.now() - this.startedAt) / 1000;
    const phase = (elapsed % eighth) / eighth;
    const duty = Math.max(0.42, 0.86 - amount * 0.4);
    return phase < duty ? 1 : 0.28;
  }

  /**
   * iOS 27 AutoMix keeps both songs full-band and beatmatched.
   * The older filter, echo and plate read as the underwater wash Apple dropped.
   */
  private appleBlend(): boolean {
    return this.params.dsp.mashupMode !== "oneBarDuet";
  }

  private heardVolumes(progress: number): { outgoing: number; incoming: number } {
    if (this.neuralActive) return this.neuralVolumes(progress);
    if (!this.appleBlend()) return volumesAt(progress, this.params);
    const t = progress * progress * (3 - 2 * progress);
    return {
      outgoing: Math.cos(t * Math.PI * 0.5),
      incoming: Math.sin(t * Math.PI * 0.5),
    };
  }

  /** One bar of the blend, as a fraction of progress. */
  private landBar(): number {
    const bpm = this.params.targetBPM > 30 ? this.params.targetBPM : 120;
    const barSec = (4 * 60) / bpm;
    return Math.min(0.22, Math.max(0.07, barSec / Math.max(4, this.params.blendDurationSec)));
  }

  /** Ending bed holds under the next vocal, then leaves across one bar into LAND. */
  private neuralVolumes(progress: number): { outgoing: number; incoming: number } {
    const land = Math.min(0.92, Math.max(0.4, this.params.handoffAt));
    const bar = this.landBar();
    const duet = this.params.dsp.mashupMode === "oneBarDuet";
    const release = Math.max(0, land - bar);
    if (duet) {
      const swap = progress * progress * (3 - 2 * progress);
      const alive =
        progress <= release ? 1 : Math.max(0, 1 - (progress - release) / Math.max(0.08, bar));
      return {
        outgoing: (0.96 - 0.42 * swap) * alive,
        incoming: progress >= land ? 1 : 0.58 + 0.42 * swap,
      };
    }
    const bed =
      progress <= release ? 1 : Math.max(0, 1 - (progress - release) / Math.max(0.08, bar));
    const vocal = Math.min(1, progress / 0.16);
    return { outgoing: bed, incoming: progress >= land ? 1 : vocal };
  }

  private heardBass(progress: number): { outgoing: number; incoming: number } {
    if (this.neuralActive) return { outgoing: 0, incoming: 0 };
    if (!this.appleBlend()) return bassGainDbAt(progress, this.params);
    const t = progress * progress * (3 - 2 * progress);
    return { outgoing: -3.5 * t, incoming: -3.5 * (1 - t) };
  }

  private applyEnvelope(progress: number, audioTime: number, immediate: boolean) {
    if (!this.chainA || !this.chainB) return;
    const vols = this.heardVolumes(progress);
    const bass = this.heardBass(progress);
    const rates = playbackRatesAt(progress, this.params);
    const cents = pitchCentsAt(progress, this.params);
    const fx = stemFxAt(progress, this.params);
    const apple = this.appleBlend();

    const stutter = this.neuralActive && fx.stutterA > 0.08 ? this.phraseGate(fx.stutterA) : 1;
    setParam(this.chainA.gain.gain, vols.outgoing * stutter, audioTime, immediate, 0.04);
    setParam(this.chainB.gain.gain, vols.incoming, audioTime, immediate, 0.18);

    this.chainA.eq.setBassGainDb(bass.outgoing, audioTime, immediate);
    this.chainB.eq.setBassGainDb(bass.incoming, audioTime, immediate);

    // Modern Duet: keep A vocal clear; soft mid duck on B for air.
    // AutoMix: duck gated B only.
    const duet = this.params.dsp.mashupMode === "oneBarDuet";
    if (apple || this.neuralActive) {
      this.chainA.stem.setDry(audioTime, immediate);
      this.chainB.stem.setDry(audioTime, immediate);
      this.chainA.eq.setVocalDuckDb(0, audioTime, immediate);
      this.chainB.eq.setVocalDuckDb(0, audioTime, immediate);
      this.chainA.eq.setAirDb(0, audioTime, immediate);
      this.chainB.eq.setAirDb(0, audioTime, immediate);
    } else {
    this.chainA.eq.setVocalDuckDb(0, audioTime, immediate);
    this.chainB.eq.setVocalDuckDb(
      duet
        ? progress < this.params.handoffAt
          ? fx.vocalDuckBDb
          : 0
        : fx.vocalDuckBDb,
      audioTime,
      immediate
    );
    this.chainA.eq.setAirDb(duet ? 1.5 * Math.min(1, fx.vocalA) : 0, audioTime, immediate);
    this.chainB.eq.setAirDb(0, audioTime, immediate);

    if (duet) {
      // A = vocal isolate (bake already acapella; live reinforces). B stays dry.
      const liveVocal = Math.min(0.35, fx.vocalA);
      if (liveVocal > 0.04) this.chainA.stem.setVocal(liveVocal, audioTime, immediate);
      else this.chainA.stem.setDry(audioTime, immediate);
      this.chainB.stem.setDry(audioTime, immediate);
    } else {
      // Light bed only. A full mid-mute makes the track sound cut and hollow.
      const liveA = Math.min(0.28, fx.instrumentalA * this.liveInstrScale);
      this.chainA.stem.setInstrumental(liveA, audioTime, immediate, false);
      this.chainB.stem.setInstrumental(
        Math.min(0.28, fx.instrumentalB),
        audioTime,
        immediate,
        false
      );
    }
    }

    if (this.neuralActive) {
      // Loop, delay and plate play through the mashup. Across the bar
      // before the downbeat they let go; the echo rings a little past LAND.
      const land = this.params.handoffAt;
      const bar = this.landBar();
      const release = Math.max(0, land - bar);
      const exit = progress <= release ? 0 : Math.min(1, (progress - release) / (bar * 1.45));
      const entry = Math.min(1, progress / 0.18);
      const open = entry * (1 - exit);
      this.chainA.filters.setHighPass(0, audioTime, immediate);
      this.chainA.filters.setLowPass(0, audioTime, immediate);
      this.chainB.filters.setHighPass(0, audioTime, immediate);
      this.chainB.filters.setLowPass(0, audioTime, immediate);
      const echoWet = (18 + 28 * Math.min(1, Math.max(fx.echoA, 0.35))) * open;
      this.chainA.echo.setEchoOut(echoWet, 34, audioTime, immediate);
      this.chainB.echo.bypass(audioTime, immediate);
      this.chainA.reverb.setWash((0.42 + 0.35 * Math.min(1, fx.reverbA)) * open, audioTime, immediate);
      this.chainB.reverb.setWash(0.28 * open, audioTime, immediate);
    } else if (apple) {
      this.chainA.filters.setHighPass(0, audioTime, immediate);
      this.chainA.filters.setLowPass(0, audioTime, immediate);
      this.chainB.filters.setHighPass(0, audioTime, immediate);
      this.chainB.filters.setLowPass(0, audioTime, immediate);
      this.chainA.echo.bypass(audioTime, immediate);
      this.chainB.echo.bypass(audioTime, immediate);
      this.chainA.reverb.bypass(audioTime, immediate);
      this.chainB.reverb.bypass(audioTime, immediate);
    } else {
      // HPF belongs to LAND (stem envelope), not the whole mashup.
      this.chainA.filters.setHighPass(fx.hpfA, audioTime, immediate);
      this.chainA.filters.setLowPass(0, audioTime, immediate);
      this.chainB.filters.setHighPass(0, audioTime, immediate);
      this.chainB.filters.setLowPass(fx.lpfB, audioTime, immediate);

      this.chainA.echo.setAmount(fx.echoA, audioTime, immediate);
      this.chainB.echo.bypass(audioTime, immediate);
      this.chainA.reverb.setAmount(fx.reverbA, audioTime, immediate);
      this.chainB.reverb.bypass(audioTime, immediate);
    }

    const transport = beatmatchTransport(
      rates,
      cents,
      this.pitchLockedA,
      this.pitchLockedB
    );
    const musical = (rate: number) => Math.min(1.04, Math.max(0.96, rate || 1));
    try {
      setParam(this.chainA.source.playbackRate, musical(transport.rateA), audioTime, false, 0.25);
      setParam(this.chainB.source.playbackRate, musical(transport.rateB), audioTime, false, 0.25);
      setParam(this.chainA.source.detune, transport.detuneA, audioTime, false, 0.25);
      setParam(this.chainB.source.detune, transport.detuneB, audioTime, false, 0.25);
    } catch {
      /* source may have ended */
    }
  }

  private emit(progress: number) {
    const vols = this.heardVolumes(progress);
    const bass = this.heardBass(progress);
    const rates = playbackRatesAt(progress, this.params);
    const cents = pitchCentsAt(progress, this.params);
    const fx = stemFxAt(progress, this.params);
    const apple = this.appleBlend();
    const elapsed = (performance.now() - this.startedAt) / 1000;

    if (progress >= this.params.handoffAt) this.handoffSnapped = true;
    const landBar = this.neuralActive ? this.landBar() : 0;
    const landing =
      this.neuralActive &&
      progress >= this.params.handoffAt - landBar &&
      progress < this.params.handoffAt + landBar * 0.45;

    const displayDeck: DeckId = this.handoffSnapped ? "b" : "a";
    const displayElapsed = this.handoffSnapped
      ? this.params.cueBSec + elapsed
      : this.params.cueASec + elapsed;
    const displayDuration =
      displayDeck === "b" ? this.decks.b.duration || 1 : this.decks.a.duration || 1;

    this.onTick?.({
      playing: this.playing,
      progress,
      phase: landing ? "LAND" : phaseLabel(progress, this.params),
      volA: vols.outgoing,
      volB: vols.incoming,
      bassA: bass.outgoing,
      bassB: bass.incoming,
      rateA: rates.outgoing,
      rateB: rates.incoming,
      pitchB: cents,
      // Duet reports vocal isolate on instrA so coach/UI meters stay useful.
      instrA: apple
        ? 0
        : this.params.dsp.mashupMode === "oneBarDuet"
          ? fx.vocalA
          : fx.instrumentalA,
      instrB: apple ? 0 : fx.instrumentalB,
      vocalB: apple ? 0 : fx.vocalB,
      hpfA: apple ? 0 : fx.hpfA,
      lpfB: apple ? 0 : fx.lpfB,
      echoA: apple ? 0 : fx.echoA,
      reverbA: apple ? 0 : fx.reverbA,
      stutterA: apple ? 0 : fx.stutterA,
      displayElapsed: Math.min(displayDuration, Math.max(0, displayElapsed)),
      displayDuration,
      displayDeck,
      processingNote: this.processingNote || undefined,
    });
  }

  private teardownChain(chain: SourceChain | null) {
    if (!chain) return;
    try {
      chain.source.stop();
    } catch {
      /* already stopped */
    }
    try {
      chain.source.disconnect();
      chain.stem.disconnect();
      chain.eq.disconnect();
      chain.filters.disconnect();
      chain.echo.disconnect();
      chain.reverb.disconnect();
      chain.gain.disconnect();
    } catch {
      /* ignore */
    }
  }
}
