import {
  bassGainDbAt,
  phaseLabel,
  pitchCentsAt,
  playbackRatesAt,
  volumesAt,
} from "./envelopes";
import type { MashupParams } from "./envelopes";

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
  displayElapsed: number;
  displayDuration: number;
  displayDeck: DeckId;
};

type SourceChain = {
  source: AudioBufferSourceNode;
  gain: GainNode;
  bass: BiquadFilterNode;
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

    this.chainA = this.makeChain(a, cueA, p.rateA);
    this.chainB = this.makeChain(b, cueB, p.rateB);

    const now = ctx.currentTime + 0.05;
    this.startedAt = performance.now();
    this.playing = true;
    this.handoffSnapped = false;

    // Seed envelopes at t0
    this.applyEnvelope(0, now, true);

    this.chainA.source.start(now, cueA);
    this.chainB.source.start(now, cueB);

    // Stop after blend (+ small tail)
    const stopAt = now + blend + 0.4;
    try {
      this.chainA.source.stop(stopAt);
      this.chainB.source.stop(stopAt + 0.2);
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
    const chain = this.makeChain(deck.buffer, cue, rate);
    if (id === "a") this.chainA = chain;
    else this.chainB = chain;
    chain.gain.gain.value = 1;
    chain.bass.gain.value = 0;
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
        displayElapsed: cue + elapsed,
        displayDuration: deck.duration,
        displayDeck: id,
      });
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  private makeChain(buffer: AudioBuffer, _cue: number, rate: number): SourceChain {
    const ctx = this.ctx!;
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.playbackRate.value = rate;

    const gain = ctx.createGain();
    gain.gain.value = 0;

    const bass = ctx.createBiquadFilter();
    bass.type = "lowshelf";
    bass.frequency.value = 120;
    bass.gain.value = 0;

    source.connect(bass);
    bass.connect(gain);
    gain.connect(this.master!);

    return { source, gain, bass };
  }

  private applyEnvelope(progress: number, audioTime: number, immediate: boolean) {
    if (!this.chainA || !this.chainB) return;
    const vols = volumesAt(progress, this.params);
    const bass = bassGainDbAt(progress, this.params);
    const rates = playbackRatesAt(progress, this.params);
    const cents = pitchCentsAt(progress, this.params);

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
    set(this.chainA.bass.gain, bass.outgoing);
    set(this.chainB.bass.gain, bass.incoming);

    // Vinyl-style rate (tempo+pitch together) — classic DJ beatmatch feel.
    try {
      this.chainA.source.playbackRate.setTargetAtTime(rates.outgoing, audioTime, 0.04);
      this.chainB.source.playbackRate.setTargetAtTime(rates.incoming, audioTime, 0.04);
      // Extra key shift on B in cents via detune.
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
    const elapsed = (performance.now() - this.startedAt) / 1000;
    const blend = Math.max(0.001, this.params.blendDurationSec);

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
      displayElapsed: Math.min(displayDuration, Math.max(0, displayElapsed)),
      displayDuration,
      displayDeck,
    });

    if (!this.playing && progress >= 1) {
      // keep final UI state
    }
    void blend;
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
      chain.bass.disconnect();
      chain.gain.disconnect();
    } catch {
      /* ignore */
    }
  }
}
