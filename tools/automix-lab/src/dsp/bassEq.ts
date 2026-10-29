/**
 * Bass kill / bass on + simple 3-band tone EQ — written from scratch.
 *
 * Mirrors DualDeck `bassKill` / `bassOn` / mid vocal duck semantics:
 *   - lowshelf @ ~120 Hz for kick/bass ownership (the “ONE BASS” moment)
 *   - peaking mid for vocal pocket
 *   - highshelf for air when revealing B
 */

import { clamp, setParam } from "./param";

export class BassEqNode {
  readonly input: GainNode;
  readonly output: GainNode;
  readonly bass: BiquadFilterNode;
  readonly mid: BiquadFilterNode;
  readonly air: BiquadFilterNode;

  constructor(ctx: AudioContext) {
    this.input = ctx.createGain();
    this.output = ctx.createGain();

    this.bass = ctx.createBiquadFilter();
    this.bass.type = "lowshelf";
    this.bass.frequency.value = 120;
    this.bass.gain.value = 0;

    this.mid = ctx.createBiquadFilter();
    this.mid.type = "peaking";
    this.mid.frequency.value = 1400;
    this.mid.Q.value = 0.85;
    this.mid.gain.value = 0;

    this.air = ctx.createBiquadFilter();
    this.air.type = "highshelf";
    this.air.frequency.value = 6500;
    this.air.gain.value = 0;

    this.input.connect(this.bass);
    this.bass.connect(this.mid);
    this.mid.connect(this.air);
    this.air.connect(this.output);
  }

  /**
   * Bass kill amount 0…1 → 0…−15*depth dB on lowshelf.
   * depth mirrors MashupParams.bassDepth (≈1.0…1.5).
   */
  setBassKill(amount: number, depth: number, when: number, immediate = false) {
    const a = clamp(amount, 0, 1);
    const d = Math.max(0.5, depth);
    setParam(this.bass.gain, -15 * d * a, when, immediate);
  }

  /** Direct bass shelf gain in dB (engine envelopes already compute this). */
  setBassGainDb(db: number, when: number, immediate = false) {
    setParam(this.bass.gain, clamp(db, -40, 12), when, immediate);
  }

  /**
   * Vocal duck / pocket on mid band.
   * Positive amount ducks mid (dB negative); negative amount boosts presence.
   */
  setVocalDuckDb(db: number, when: number, immediate = false) {
    setParam(this.mid.gain, clamp(db, -24, 9), when, immediate);
  }

  setAirDb(db: number, when: number, immediate = false) {
    setParam(this.air.gain, clamp(db, -12, 9), when, immediate);
  }

  disconnect() {
    try {
      this.input.disconnect();
      this.bass.disconnect();
      this.mid.disconnect();
      this.air.disconnect();
      this.output.disconnect();
    } catch {
      /* ignore */
    }
  }
}
