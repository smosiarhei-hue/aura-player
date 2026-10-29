/**
 * Tempo-synced echo / echo-out — written from scratch (Web Audio DelayNode).
 *
 * Mirrors DualDeck `echoOut`:
 *   delayTime ≈ 0.75 beat at current BPM
 *   wet 0…0.75, feedback 0…0.6
 *
 * Used on outgoing deck near LAND so A’s last hook rings over B.
 */

import { clamp, setParam } from "./param";

export class EchoOutNode {
  readonly input: GainNode;
  readonly output: GainNode;
  private dry: GainNode;
  private wet: GainNode;
  private delay: DelayNode;
  private feedback: GainNode;
  private filter: BiquadFilterNode;

  constructor(ctx: AudioContext) {
    this.input = ctx.createGain();
    this.output = ctx.createGain();
    this.dry = ctx.createGain();
    this.wet = ctx.createGain();
    this.delay = ctx.createDelay(2.0);
    this.feedback = ctx.createGain();
    this.filter = ctx.createBiquadFilter();

    this.dry.gain.value = 1;
    this.wet.gain.value = 0;
    this.feedback.gain.value = 0.3;
    this.delay.delayTime.value = 0.375;

    // Soft LPF in the feedback loop so echoes darken (classic DJ echo-out).
    this.filter.type = "lowpass";
    this.filter.frequency.value = 4200;
    this.filter.Q.value = 0.5;

    // Dry path
    this.input.connect(this.dry);
    this.dry.connect(this.output);

    // Wet / feedback path
    this.input.connect(this.delay);
    this.delay.connect(this.filter);
    this.filter.connect(this.wet);
    this.wet.connect(this.output);
    this.filter.connect(this.feedback);
    this.feedback.connect(this.delay);
  }

  /** Set delay time from BPM (0.75 of a beat, clamped). */
  setTempo(bpm: number, when: number, immediate = false) {
    const beat = bpm > 30 ? 60 / bpm : 0.5;
    const t = clamp(beat * 0.75, 0.05, 2);
    setParam(this.delay.delayTime, t, when, immediate, 0.02);
  }

  /**
   * Echo-out intensity.
   * amount 0…1 → wet 0…0.7, feedback 0.25…0.6
   */
  setAmount(amount: number, when: number, immediate = false) {
    const a = clamp(amount, 0, 1);
    setParam(this.wet.gain, 0.7 * a, when, immediate);
    setParam(this.feedback.gain, 0.25 + 0.35 * a, when, immediate);
    // Keep dry present; echo sits on top (not a full wet takeover).
    setParam(this.dry.gain, 1 - 0.15 * a, when, immediate);
  }

  /** Direct wet % (0…75) and optional feedback % (0…60), DualDeck-compatible. */
  setEchoOut(wetPercent: number, feedbackPercent: number | undefined, when: number, immediate = false) {
    const wet = clamp(wetPercent, 0, 75) / 100;
    const fb = clamp(feedbackPercent ?? 30, 0, 60) / 100;
    setParam(this.wet.gain, wet, when, immediate);
    setParam(this.feedback.gain, fb, when, immediate);
    setParam(this.dry.gain, 1 - wet * 0.2, when, immediate);
  }

  bypass(when: number, immediate = false) {
    this.setAmount(0, when, immediate);
  }

  disconnect() {
    try {
      this.input.disconnect();
      this.dry.disconnect();
      this.wet.disconnect();
      this.delay.disconnect();
      this.feedback.disconnect();
      this.filter.disconnect();
      this.output.disconnect();
    } catch {
      /* ignore */
    }
  }
}
