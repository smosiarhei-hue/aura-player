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
  stemFxAt,
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
  /** Stem / FX meters for UI. */
  instrA: number;
  vocalB: number;
  hpfA: number;
  lpfB: number;
  echoA: number;
  displayElapsed: number;
  displayDuration: number;
  displayDeck: DeckId;
};

/**
 * Full dual-deck chain (written with our DSP toolkit):
 *   source → Mid/Side stem → Bass EQ → HPF/LPF → Echo → Gain → master
 */
type SourceChain = {
  source: AudioBufferSourceNode;
  stem: MidSideStemNode;
  eq: BassEqNode;
  filters: FilterSweepNode;
  echo: EchoOutNode;
  gain: GainNode;
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

  constructor(params: MashupParams) {
    this.params = { ...params };
  }

  setParams(params: MashupParams) {
    this.params = { ...params };
  }

  getParams() {
    return { ...this.params };
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

  async playMashup() {
    const a = this.decks.a.buffer;
    const b = this.decks.b.buffer;
    if (!a || !b) throw new Error("Загрузи оба трека");
    const ctx = await this.ensureContext();
    this.stop();

    const p = this.params;
    const cueA = Math.min(Math.max(0, p.cueASec), Math.max(0, a.duration - 1));
    const cueB = Math.min(Math.max(0, p.cueBSec), Math.max(0, b.duration - 1));
    const blend = Math.max(4, Math.min(48, p.blendDurationSec));

    this.chainA = this.makeChain(a, p.rateA);
    this.chainB = this.makeChain(b, p.rateB);

    const now = ctx.currentTime + 0.05;
    this.startedAt = performance.now();
    this.playing = true;
    this.handoffSnapped = false;

    // Tempo-sync echo delays to target / deck BPM.
    const bpm =
      p.targetBPM > 30
        ? p.targetBPM
        : this.decks.a.bpm > 30
          ? this.decks.a.bpm
          : 120;
    this.chainA.echo.setTempo(bpm, now, true);
    this.chainB.echo.setTempo(this.decks.b.bpm || bpm, now, true);

    this.applyEnvelope(0, now, true);

    this.chainA.source.start(now, cueA);
    this.chainB.source.start(now, cueB);

    const stopAt = now + blend + 0.6;
    try {
      this.chainA.source.stop(stopAt);
      this.chainB.source.stop(stopAt + 0.35);
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
        this.emit(1);
        return;
      }
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  async playSolo(id: DeckId, fromSec?: number) {
    const deck = this.decks[id];
    if (!deck.buffer) throw new Error("Нет трека");
    const ctx = await this.ensureContext();
    this.stop();
    const cue = fromSec ?? (id === "a" ? this.params.cueASec : this.params.cueBSec);
    const rate = id === "a" ? this.params.rateA : this.params.rateB;
    const chain = this.makeChain(deck.buffer, rate);
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
    chain.source.start(now, Math.max(0, cue));
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

  private makeChain(buffer: AudioBuffer, rate: number): SourceChain {
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

    // source → stem → eq → filters → echo → gain → master
    source.connect(stem.input);
    stem.output.connect(eq.input);
    eq.output.connect(filters.input);
    filters.output.connect(echo.input);
    echo.output.connect(gain);
    gain.connect(this.master!);

    return { source, stem, eq, filters, echo, gain };
  }

  private applyEnvelope(progress: number, audioTime: number, immediate: boolean) {
    if (!this.chainA || !this.chainB) return;
    const vols = volumesAt(progress, this.params);
    const bass = bassGainDbAt(progress, this.params);
    const rates = playbackRatesAt(progress, this.params);
    const cents = pitchCentsAt(progress, this.params);
    const fx = stemFxAt(progress, this.params);

    const set = (param: AudioParam, value: number) => {
      if (immediate) {
        param.cancelScheduledValues(audioTime);
        param.setValueAtTime(value, audioTime);
      } else {
        param.linearRampToValueAtTime(value, audioTime + 0.03);
      }
    };

    set(this.chainA.gain.gain, vols.outgoing);
    set(this.chainB.gain.gain, vols.incoming);

    // Bass ownership (ONE BASS)
    this.chainA.eq.setBassGainDb(bass.outgoing, audioTime, immediate);
    this.chainB.eq.setBassGainDb(bass.incoming, audioTime, immediate);
    this.chainA.eq.setVocalDuckDb(0, audioTime, immediate);
    this.chainB.eq.setVocalDuckDb(fx.vocalDuckBDb, audioTime, immediate);
    this.chainA.eq.setAirDb(-1.5 * fx.hpfA, audioTime, immediate);
    this.chainB.eq.setAirDb(1.5 * (1 - fx.lpfB), audioTime, immediate);

    // Stem tools: A instrumentalize, B vocalize
    this.chainA.stem.setInstrumental(fx.instrumentalA, audioTime, immediate);
    this.chainB.stem.setVocal(fx.vocalB, audioTime, immediate);

    // Filters
    this.chainA.filters.setHighPass(fx.hpfA, audioTime, immediate);
    this.chainA.filters.setLowPass(0, audioTime, immediate);
    this.chainB.filters.setHighPass(0, audioTime, immediate);
    this.chainB.filters.setLowPass(fx.lpfB, audioTime, immediate);

    // Echo-out on A near LAND
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

    const pastHandoff = progress >= this.params.handoffAt;
    if (pastHandoff) this.handoffSnapped = true;

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
      vocalB: fx.vocalB,
      hpfA: fx.hpfA,
      lpfB: fx.lpfB,
      echoA: fx.echoA,
      displayElapsed: Math.min(displayDuration, Math.max(0, displayElapsed)),
      displayDuration,
      displayDeck,
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
