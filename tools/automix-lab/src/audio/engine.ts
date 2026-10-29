import {
  bassGainDbAt,
  phaseLabel,
  pitchCentsAt,
  playbackRatesAt,
  volumesAt,
} from "./envelopes";
import type { MashupParams } from "./envelopes";
import {
  BassEqNode,
  EchoOutNode,
  FilterSweepNode,
  MidSideStemNode,
  bakeStemSlice,
  bakeInstrThenDry,
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

  setBpm(id: DeckId, bpm: number) {
    this.decks[id].bpm = Math.max(40, Math.min(220, bpm));
  }

  stop() {
    this.playing = false;
    cancelAnimationFrame(this.raf);
    this.teardownChain(this.chainA);
    this.teardownChain(this.chainB);
    this.chainA = null;
    this.chainB = null;
    this.handoffSnapped = false;
    this.emit(0);
  }

  /**
   * Full auto path: bake stems from recipe → play mashup.
   * Call after setParams(plan.params).
   */
  async playAutoMashup(onStatus?: (msg: string) => void): Promise<void> {
    const a = this.decks.a.buffer;
    const b = this.decks.b.buffer;
    if (!a || !b) throw new Error("Загрузи оба трека");
    const ctx = await this.ensureContext();
    this.stop();

    const p = this.params;
    const dsp = p.dsp;
    const cueA = Math.min(Math.max(0, p.cueASec), Math.max(0, a.duration - 1));
    const cueB = Math.min(Math.max(0, p.cueBSec), Math.max(0, b.duration - 1));
    const blend = Math.max(4, Math.min(48, p.blendDurationSec));

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

    if (dsp.bakeStems) {
      // Bake only where ONE VOCAL needs a carve — never blanket-duck / thin the mix.
      if (dsp.bakeInstrA && dsp.instrAPeak >= 0.35) {
        onStatus?.(`Bake A lead carve ${Math.round(dsp.instrAPeak * 100)}%…`);
        // Softer amount so the bed stays bright; live graph can reinforce if needed.
        const amt = Math.min(0.85, dsp.instrAPeak);
        bufA = bakeStemSlice(ctx, a, cueA, blend, "instrumental", amt);
        offsetA = 0;
        liveInstrScale = 0.25; // avoid double-muffling on top of bake
      }

      if (dsp.bakeInstrB && dsp.instrBPeak >= 0.5) {
        const untilSec = Math.max(
          0.4,
          blend * Math.min(0.75, Math.max(0.12, dsp.instrBUntil))
        );
        onStatus?.(
          `Bake B groove → dry @ ${untilSec.toFixed(1)}s (${modeLabel})…`
        );
        bufB = bakeInstrThenDry(
          ctx,
          b,
          cueB,
          blend,
          untilSec,
          Math.min(0.8, dsp.instrBPeak)
        );
        offsetB = 0;
      }
      // Never bake B as "vocal" stem — that thins the whole incoming track.
    }

    onStatus?.("Сведение мэшапа…");
    this.processingNote = dsp.decisions[0] ?? modeLabel;

    this.chainA = this.makeChain(bufA, p.rateA, offsetA);
    this.chainB = this.makeChain(bufB, p.rateB, offsetB);

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

    const tick = () => {
      if (!this.playing) return;
      const elapsed = (performance.now() - this.startedAt) / 1000;
      const progress = Math.min(1, elapsed / blend);
      this.applyEnvelope(progress, ctx.currentTime, false);
      this.emit(progress);
      if (progress >= 1) {
        this.playing = false;
        this.processingNote = "";
        this.emit(1);
        return;
      }
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  /** Manual play without re-baking (uses current params + live DSP only). */
  async playMashup() {
    return this.playAutoMashup();
  }

  private liveInstrScale = 1;

  async playSolo(id: DeckId, fromSec?: number) {
    const deck = this.decks[id];
    if (!deck.buffer) throw new Error("Нет трека");
    const ctx = await this.ensureContext();
    this.stop();
    const cue = fromSec ?? (id === "a" ? this.params.cueASec : this.params.cueBSec);
    const rate = id === "a" ? this.params.rateA : this.params.rateB;
    const chain = this.makeChain(deck.buffer, rate, Math.max(0, cue));
    if (id === "a") this.chainA = chain;
    else this.chainB = chain;
    chain.gain.gain.value = 1;
    chain.eq.setBassGainDb(0, ctx.currentTime, true);
    chain.stem.setDry(ctx.currentTime, true);
    chain.filters.setOpen(ctx.currentTime, true);
    chain.echo.bypass(ctx.currentTime, true);
    const now = ctx.currentTime + 0.05;
    this.startedAt = performance.now();
    this.playing = true;
    this.processingNote = "";
    chain.source.start(now, chain.startOffset);
    const tick = () => {
      if (!this.playing) return;
      const elapsed = (performance.now() - this.startedAt) / 1000;
      this.onTick?.({
        playing: true,
        progress: 0,
        phase: `SOLO ${id.toUpperCase()}`,
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
        displayElapsed: cue + elapsed,
        displayDuration: deck.duration,
        displayDeck: id,
      });
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
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

    // Shared cancelAndHold + ramp (see dsp/param) — no stacked linearRamp clicks.
    setParam(this.chainA.gain.gain, vols.outgoing, audioTime, immediate, 0.08);
    setParam(this.chainB.gain.gain, vols.incoming, audioTime, immediate, 0.08);

    this.chainA.eq.setBassGainDb(bass.outgoing, audioTime, immediate);
    this.chainB.eq.setBassGainDb(bass.incoming, audioTime, immediate);
    this.chainA.eq.setVocalDuckDb(0, audioTime, immediate);
    // Mid duck only while B is still gated instrumental — not a constant muff.
    this.chainB.eq.setVocalDuckDb(fx.vocalDuckBDb, audioTime, immediate);
    // Don't steal air with negative shelves; keep tone even.
    this.chainA.eq.setAirDb(0, audioTime, immediate);
    this.chainB.eq.setAirDb(0, audioTime, immediate);

    // Continuous stem amounts (0 ≡ dry) — never hard-switch setDry/setInstrumental.
    const liveA = fx.instrumentalA * this.liveInstrScale;
    this.chainA.stem.setInstrumental(liveA, audioTime, immediate);
    const conflictGate = this.params.dsp.instrBPeak >= 0.5;
    const beforeVocalOpen = progress < Math.max(0.05, this.params.dsp.vocalBAt);
    const liveB = Math.min(
      0.85,
      Math.max(fx.instrumentalB, conflictGate && beforeVocalOpen ? 0.7 : 0)
    );
    this.chainB.stem.setInstrumental(liveB, audioTime, immediate);

    this.chainA.filters.setHighPass(fx.hpfA, audioTime, immediate);
    this.chainA.filters.setLowPass(0, audioTime, immediate);
    this.chainB.filters.setHighPass(0, audioTime, immediate);
    this.chainB.filters.setLowPass(fx.lpfB, audioTime, immediate);

    this.chainA.echo.setAmount(fx.echoA, audioTime, immediate);
    this.chainB.echo.bypass(audioTime, immediate);

    try {
      this.chainA.source.playbackRate.setTargetAtTime(rates.outgoing, audioTime, 0.04);
      this.chainB.source.playbackRate.setTargetAtTime(rates.incoming, audioTime, 0.04);
      this.chainB.source.detune.setTargetAtTime(cents, audioTime, 0.05);
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
