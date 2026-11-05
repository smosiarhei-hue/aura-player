/**
 * Musical plate wash for Space Reverb transitions.
 *
 * Parallel tempo-ish delays + one-pole damping — not HRTF / Spatial Audio.
 * Mirrors DualDeck `reverbWash` / stream MixFX plate intent.
 */

import { clamp, setParam } from "./param";

export class ReverbWashNode {
  readonly input: GainNode;
  readonly output: GainNode;
  private dry: GainNode;
  private wet: GainNode;
  private delays: DelayNode[] = [];
  private feedbacks: GainNode[] = [];
  private damp: BiquadFilterNode;

  constructor(ctx: AudioContext) {
    this.input = ctx.createGain();
    this.output = ctx.createGain();
    this.dry = ctx.createGain();
    this.wet = ctx.createGain();
    this.damp = ctx.createBiquadFilter();

    this.dry.gain.value = 1;
    this.wet.gain.value = 0;
    this.damp.type = "lowpass";
    this.damp.frequency.value = 5200;
    this.damp.Q.value = 0.5;

    this.input.connect(this.dry);
    this.dry.connect(this.output);

    // Three short taps ≈ small hall / plate (ms), stereo-ish by offset.
    const taps = [0.029, 0.037, 0.053];
    const fbs = [0.22, 0.18, 0.16];
    for (let i = 0; i < taps.length; i++) {
      const delay = ctx.createDelay(0.2);
      const fb = ctx.createGain();
      delay.delayTime.value = taps[i]!;
      fb.gain.value = fbs[i]!;
      this.input.connect(delay);
      delay.connect(this.damp);
      this.damp.connect(fb);
      fb.connect(delay);
      delay.connect(this.wet);
      this.delays.push(delay);
      this.feedbacks.push(fb);
    }
    this.wet.connect(this.output);
  }

  /**
   * Light plate on top of a full dry signal. Wet tops out near 16%.
   * Dry is never ducked — the wash must not thin the track.
   */
  setAmount(amount: number, when: number, immediate = false) {
    const a = clamp(amount, 0, 1);
    setParam(this.wet.gain, 0.16 * a, when, immediate, 0.18);
    setParam(this.dry.gain, 1, when, immediate, 0.18);
    const dampHz = 6400 - 800 * a;
    setParam(this.damp.frequency, dampHz, when, immediate, 0.18);
  }

  bypass(when: number, immediate = false) {
    this.setAmount(0, when, immediate);
  }

  disconnect() {
    try {
      this.input.disconnect();
      this.dry.disconnect();
      this.wet.disconnect();
      this.damp.disconnect();
      for (const d of this.delays) d.disconnect();
      for (const f of this.feedbacks) f.disconnect();
      this.output.disconnect();
    } catch {
      /* ignore */
    }
  }
}
