/**
 * High-pass / low-pass sweep tools — written from scratch.
 *
 * DJ grammar:
 *   - HPF riser on outgoing (LAND): cut mud, leave sparkle as A exits
 *   - LPF closed→open on incoming (INVITE): B emerges from under a blanket
 *
 * Frequency maps match DualDeck applyEffect highPass/lowPass ranges.
 */

import { clamp, setParam } from "./param";

export class FilterSweepNode {
  readonly input: GainNode;
  readonly output: GainNode;
  readonly hpf: BiquadFilterNode;
  readonly lpf: BiquadFilterNode;

  constructor(ctx: AudioContext) {
    this.input = ctx.createGain();
    this.output = ctx.createGain();

    this.hpf = ctx.createBiquadFilter();
    this.hpf.type = "highpass";
    this.hpf.frequency.value = 20;
    this.hpf.Q.value = 0.707;

    this.lpf = ctx.createBiquadFilter();
    this.lpf.type = "lowpass";
    this.lpf.frequency.value = 20000;
    this.lpf.Q.value = 0.707;

    this.input.connect(this.hpf);
    this.hpf.connect(this.lpf);
    this.lpf.connect(this.output);
  }

  /** Open HPF: amount 0 = bypass (~20 Hz), 1 ≈ 4–6 kHz riser. */
  setHighPass(amount: number, when: number, immediate = false) {
    const a = clamp(amount, 0, 1);
    // Exponential-ish feel: more movement in the musical midrange.
    const hz = 20 * Math.pow(300, a); // 20 → ~6000
    const q = 0.7 + a * 0.55;
    setParam(this.hpf.frequency, hz, when, immediate, 0.05);
    setParam(this.hpf.Q, q, when, immediate, 0.05);
  }

  /** Direct HPF frequency in Hz (20…18000). */
  setHighPassHz(hz: number, when: number, immediate = false) {
    setParam(this.hpf.frequency, clamp(hz, 20, 18000), when, immediate, 0.05);
  }

  /** Close LPF: amount 0 = open (~20 kHz), 1 ≈ 200–400 Hz muffling. */
  setLowPass(amount: number, when: number, immediate = false) {
    const a = clamp(amount, 0, 1);
    const hz = 20000 / Math.pow(80, a); // 20000 → ~250
    const q = 0.7 + a * 0.4;
    setParam(this.lpf.frequency, hz, when, immediate, 0.05);
    setParam(this.lpf.Q, q, when, immediate, 0.05);
  }

  setLowPassHz(hz: number, when: number, immediate = false) {
    setParam(this.lpf.frequency, clamp(hz, 100, 20000), when, immediate, 0.05);
  }

  /** Reset both filters to transparent. */
  setOpen(when: number, immediate = false) {
    this.setHighPass(0, when, immediate);
    this.setLowPass(0, when, immediate);
  }

  disconnect() {
    try {
      this.input.disconnect();
      this.hpf.disconnect();
      this.lpf.disconnect();
      this.output.disconnect();
    } catch {
      /* ignore */
    }
  }
}
