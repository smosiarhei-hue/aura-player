import {
  bassGainDbAt,
  phaseLabel,
  pitchCentsAt,
  playbackRatesAt,
  volumesAt,
  wantsLeadKill,
} from "./envelopes";
import type { MashupParams } from "./envelopes";
import { runMixCritic } from "./mixCritic";
import {
  BassEqNode,
  EchoOutNode,
  FilterSweepNode,
  MidSideStemNode,
  bakeStemSlice,
  bakeInstrThenDry,
  beatmatchTransport,
  stemFxAt,
  setParam,
  stretchPlaybackWindow,
  tempoNeedsPitchLock,
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
  gain: GainNode;
  /** Baked slices start at 0; full-buffer playback uses cue offset. */
  startOffset: number;
};

export class AutomixEngine {
  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
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
      this.master.gain.value = 0.95;
      this.master.connect(this.ctx.destination);
    }
    if (this.ctx.state === "suspended") await this.ctx.resume();
    return this.ctx;
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
    this.emit(0);
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
    this.stop();

    const p = this.params;
    const dsp = p.dsp;
    const cueA = Math.min(Math.max(0, p.cueASec), Math.max(0, a.duration - 1));
    const cueB = Math.min(Math.max(0, p.cueBSec), Math.max(0, b.duration - 1));
    // Adaptive Duet + AutoMix: never shorter than 4s (no blink).
    const blendFloor = 4;
    const blend = Math.max(blendFloor, Math.min(48, p.blendDurationSec));

    const modeLabel = dsp.mashupMode || "mashup";
    onStatus?.(`Modern mashup · ${modeLabel} — обрабатываю окно…`);
    this.processingNote = `baking ${modeLabel}`;

    // Yield so UI can paint status
    await new Promise((r) => setTimeout(r, 0));

    let bufA = a;
    let bufB = b;
    let offsetA = cueA;
    let offsetB = cueB;
    let liveInstrScale = 1;
    this.bakedLeadA = false;
    this.bakedLeadB = false;
    this.pitchLockedA = false;
    this.pitchLockedB = false;

    // Pitch-preserving beatmatch. playbackRate would also shift pitch, and
    // inverse detune on the same node cancels the tempo (they compound).
    // WSOLA bakes playbackRatesAt into the buffer; Camelot stays on detune.
    const outDur = blend + 2.6;
    const outputRate = (side: "a" | "b") => (prog: number) => {
      const t = prog * outDur;
      if (t >= blend) return 1;
      const rates = playbackRatesAt(Math.min(1, t / blend), this.params);
      return side === "a" ? rates.outgoing : rates.incoming;
    };
    if (tempoNeedsPitchLock(p.rateA) && a.duration - cueA > 0.5) {
      onStatus?.("Time-stretch A · pitch lock…");
      await new Promise((r) => setTimeout(r, 0));
      try {
        bufA = stretchPlaybackWindow(ctx, a, cueA, outDur, outputRate("a"));
        offsetA = 0;
        this.pitchLockedA = true;
      } catch (err) {
        console.warn("time-stretch A skipped", err);
      }
    }
    if (tempoNeedsPitchLock(p.rateB) && b.duration - cueB > 0.5) {
      onStatus?.("Time-stretch B · pitch lock…");
      await new Promise((r) => setTimeout(r, 0));
      try {
        bufB = stretchPlaybackWindow(ctx, b, cueB, outDur, outputRate("b"));
        offsetB = 0;
        this.pitchLockedB = true;
      } catch (err) {
        console.warn("time-stretch B skipped", err);
      }
    }

    const leadKill = wantsLeadKill(dsp);
    const carve = leadKill ? "leadKill" : "bed";

    if (leadKill || dsp.bakeStems) {
      // Acapella Drop / high instrAPeak: leadKill the bed, then B groove→dry.
      if (leadKill || (dsp.bakeInstrA && dsp.instrAPeak >= 0.35)) {
        onStatus?.(
          leadKill
            ? `Bake A lead-kill bed ${Math.round((dsp.instrAPeak || 0.95) * 100)}%…`
            : `Bake A instrumental bed ${Math.round(dsp.instrAPeak * 100)}%…`
        );
        const amt = leadKill
          ? Math.min(1, Math.max(0.94, dsp.instrAPeak || 0.95))
          : Math.min(0.92, Math.max(0.8, dsp.instrAPeak));
        bufA = bakeStemSlice(ctx, bufA, offsetA, blend, "instrumental", amt, carve);
        offsetA = 0;
        liveInstrScale = leadKill ? 0.85 : 0.35;
        this.bakedLeadA = leadKill;
        if (leadKill) {
          dsp.bakeInstrA = true;
          dsp.bakeStems = true;
        }
      }

      // Acapella Drop / high instrAPeak: hold B's lead out, then bloom dry.
      // Same carve as A so the early window is one vocal, not a second singer.
      if (leadKill || (dsp.bakeInstrB && dsp.instrBPeak >= 0.5)) {
        const openFrac = Math.min(
          0.72,
          Math.max(0.08, dsp.instrAAt + 0.04, dsp.instrBUntil || 0, dsp.vocalBAt || 0)
        );
        const untilSec = Math.max(0.35, blend * openFrac);
        onStatus?.(`Bake B instr → vocal @ ${untilSec.toFixed(1)}s (${modeLabel})…`);
        const bAmt = leadKill
          ? Math.min(0.95, Math.max(0.82, dsp.instrBPeak || 0.9))
          : Math.min(0.92, Math.max(0.8, dsp.instrBPeak));
        bufB = bakeInstrThenDry(
          ctx,
          bufB,
          offsetB,
          blend,
          untilSec,
          bAmt,
          leadKill ? "leadKill" : "bed"
        );
        offsetB = 0;
        this.bakedLeadB = leadKill;
      }
    }

    onStatus?.("Сведение мэшапа…");
    this.processingNote = dsp.decisions[0] ?? modeLabel;

    this.chainA = this.makeChain(bufA, this.pitchLockedA ? 1 : p.rateA, offsetA);
    this.chainB = this.makeChain(bufB, this.pitchLockedB ? 1 : p.rateB, offsetB);

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

    this.applyEnvelope(0, now, true);

    this.chainA.source.start(now, this.chainA.startOffset);
    this.chainB.source.start(now, this.chainB.startOffset);

    const stopAt = now + blend + 0.8;
    try {
      this.chainA.source.stop(stopAt);
      this.chainB.source.stop(stopAt + 0.4);
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
    this.bakedLeadA = false;
    this.bakedLeadB = false;

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
      this.chainB.source.stop(now + blend + 0.6);
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
  private bakedLeadA = false;
  /** Blend was offline time-stretched; playbackRate stays 1, Camelot is detune-only. */
  private pitchLockedA = false;
  private pitchLockedB = false;
  private bakedLeadB = false;

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
    const gain = ctx.createGain();
    gain.gain.value = 0;

    source.connect(stem.input);
    stem.output.connect(eq.input);
    eq.output.connect(filters.input);
    filters.output.connect(echo.input);
    echo.output.connect(gain);
    gain.connect(this.master!);

    return { source, stem, eq, filters, echo, gain, startOffset };
  }

  private applyEnvelope(progress: number, audioTime: number, immediate: boolean) {
    if (!this.chainA || !this.chainB) return;
    const vols = volumesAt(progress, this.params);
    const bass = bassGainDbAt(progress, this.params);
    const rates = playbackRatesAt(progress, this.params);
    const cents = pitchCentsAt(progress, this.params);
    const fx = stemFxAt(progress, this.params);

    const leadKillLive = wantsLeadKill(this.params.dsp);
    // Bake already lead-kills A. A second full notch hollows the bed.
    const bakedRelay = this.bakedLeadA;
    // Shared cancelAndHold + ramp (see dsp/param) — no stacked linearRamp clicks.
    setParam(this.chainA.gain.gain, vols.outgoing, audioTime, immediate, 0.08);
    setParam(this.chainB.gain.gain, vols.incoming, audioTime, immediate, 0.08);

    this.chainA.eq.setBassGainDb(bass.outgoing, audioTime, immediate);
    this.chainB.eq.setBassGainDb(bass.incoming, audioTime, immediate);

    // Mid duck only while B is still gated instrumental — not a constant muff.
    this.chainA.eq.setVocalDuckDb(0, audioTime, immediate);
    this.chainB.eq.setVocalDuckDb(fx.vocalDuckBDb, audioTime, immediate);
    this.chainA.eq.setAirDb(0, audioTime, immediate);
    this.chainB.eq.setAirDb(0, audioTime, immediate);

    // Continuous stem amounts (0 ≡ dry) — never hard-switch setDry/setInstrumental.
    if (bakedRelay) {
      // Bake already removed the center lead. A light notch only — a second
      // full mid mute thins the kick that the carve kept.
      this.chainA.stem.setInstrumental(0.22, audioTime, immediate, true);
    } else if (leadKillLive && fx.instrumentalA >= 0.75) {
      this.chainA.stem.setInstrumental(Math.max(0.9, fx.instrumentalA), audioTime, immediate, true);
    } else if (leadKillLive) {
      this.chainA.stem.setInstrumental(fx.instrumentalA, audioTime, immediate, false);
    } else {
      const raw = Math.max(
        fx.instrumentalA * this.liveInstrScale,
        fx.instrumentalA >= 0.85 ? 0.35 : 0
      );
      // Acapella without a vocal bake: the envelope says "bed" for the gates,
      // but the outro is already instrumental — don't notch it into a whisper.
      const liveA =
        this.params.dsp.mashupMode === "acapellaDrop" && !leadKillLive
          ? Math.min(raw, 0.22)
          : raw;
      this.chainA.stem.setInstrumental(liveA, audioTime, immediate, false);
    }
    // Envelope already holds B instrumental until the vocal open — no second gate.
    // A leadKill bake already cleared B's center; don't notch that kick again.
    this.chainB.stem.setInstrumental(
      this.bakedLeadB ? Math.min(0.2, fx.instrumentalB) : Math.min(0.97, fx.instrumentalB),
      audioTime,
      immediate,
      false
    );

    // HPF belongs to LAND (stem envelope), not the whole mashup.
    this.chainA.filters.setHighPass(fx.hpfA, audioTime, immediate);
    this.chainA.filters.setLowPass(0, audioTime, immediate);
    this.chainB.filters.setHighPass(0, audioTime, immediate);
    this.chainB.filters.setLowPass(fx.lpfB, audioTime, immediate);

    this.chainA.echo.setAmount(fx.echoA, audioTime, immediate);
    this.chainB.echo.bypass(audioTime, immediate);

    const transport = beatmatchTransport(
      rates,
      cents,
      this.pitchLockedA,
      this.pitchLockedB
    );
    try {
      this.chainA.source.playbackRate.setTargetAtTime(transport.rateA, audioTime, 0.04);
      this.chainB.source.playbackRate.setTargetAtTime(transport.rateB, audioTime, 0.04);
      this.chainA.source.detune.setTargetAtTime(transport.detuneA, audioTime, 0.05);
      this.chainB.source.detune.setTargetAtTime(transport.detuneB, audioTime, 0.05);
    } catch {
      /* source may have ended */
    }
  }

  private emit(progress: number) {
    const vols = volumesAt(progress, this.params);
    const bass = bassGainDbAt(progress, this.params);
    const rates = playbackRatesAt(progress, this.params);
    const cents = pitchCentsAt(progress, this.params);
    const fx = stemFxAt(progress, this.params);
    const elapsed = (performance.now() - this.startedAt) / 1000;

    if (progress >= this.params.handoffAt) this.handoffSnapped = true;

    const displayDeck: DeckId = this.handoffSnapped ? "b" : "a";
    const displayElapsed = this.handoffSnapped
      ? this.params.cueBSec + elapsed
      : this.params.cueASec + elapsed;
    const displayDuration =
      displayDeck === "b" ? this.decks.b.duration || 1 : this.decks.a.duration || 1;

    this.onTick?.({
      playing: this.playing,
      progress,
      phase: phaseLabel(progress, this.params),
      volA: vols.outgoing,
      volB: vols.incoming,
      bassA: bass.outgoing,
      bassB: bass.incoming,
      rateA: rates.outgoing,
      rateB: rates.incoming,
      pitchB: cents,
      instrA: fx.instrumentalA,
      instrB: fx.instrumentalB,
      vocalB: fx.vocalB,
      hpfA: fx.hpfA,
      lpfB: fx.lpfB,
      echoA: fx.echoA,
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
      chain.gain.disconnect();
    } catch {
      /* ignore */
    }
  }
}
