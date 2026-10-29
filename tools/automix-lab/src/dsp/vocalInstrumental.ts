/**
 * Vocal / instrumental tools — written from scratch (no ML stems).
 *
 * Stereo DJ trick used for decades:
 *   Mid  = (L + R) / 2  → usually vocals + kick + bass (center)
 *   Side = (L − R) / 2  → usually stereo instruments / FX / doubles
 *
 * - instrumentalize: duck Mid (cut centered vocal), keep Side
 * - vocalize:        duck Side, keep/boost Mid presence
 *
 * Not perfect Demucs stems — but real, audible, and what club tools often
 * approximate when stems aren’t available.
 */

export type StemMode = "dry" | "instrumental" | "vocal";

/** Offline render: produce a new AudioBuffer in the chosen stem mode. */
export function processBufferStem(
  ctx: BaseAudioContext,
  input: AudioBuffer,
  mode: StemMode,
  amount = 1
): AudioBuffer {
  const ch = input.numberOfChannels;
  const n = input.length;
  const sr = input.sampleRate;
  const out = ctx.createBuffer(Math.min(2, Math.max(2, ch)), n, sr);

  const L = input.getChannelData(0);
  const R = ch > 1 ? input.getChannelData(1) : input.getChannelData(0);
  const oL = out.getChannelData(0);
  const oR = out.getChannelData(1);
  const a = Math.min(1, Math.max(0, amount));

  for (let i = 0; i < n; i++) {
    const l = L[i]!;
    const r = R[i]!;
    const mid = (l + r) * 0.5;
    const side = (l - r) * 0.5;

    if (mode === "dry") {
      oL[i] = l;
      oR[i] = r;
    } else if (mode === "instrumental") {
      // Remove centered vocal: attenuate mid, keep side (+ a bit of mid bass later via FX).
      const midKeep = mid * (1 - 0.92 * a);
      oL[i] = midKeep + side;
      oR[i] = midKeep - side;
    } else {
      // Vocal focus: keep mid, shrink side bed.
      const sideKeep = side * (1 - 0.85 * a);
      oL[i] = mid + sideKeep;
      oR[i] = mid - sideKeep;
    }
  }
  return out;
}

/**
 * Realtime Mid/Side splitter graph.
 * `instrumentalAmt` 0…1 ducks mid (vocal out).
 * `vocalAmt` 0…1 ducks side (instrumental bed out).
 */
export class MidSideStemNode {
  readonly input: GainNode;
  readonly output: GainNode;
  private midGain: GainNode;
  private sideGain: GainNode;

  constructor(ctx: AudioContext) {
    this.input = ctx.createGain();
    this.output = ctx.createGain();

    const split = ctx.createChannelSplitter(2);
    const merge = ctx.createChannelMerger(2);

    // Decode L/R into mid/side using gain phase tricks:
    // mid  = 0.5*L + 0.5*R
    // side = 0.5*L - 0.5*R
    const lToMid = ctx.createGain();
    const rToMid = ctx.createGain();
    const lToSide = ctx.createGain();
    const rToSide = ctx.createGain();
    lToMid.gain.value = 0.5;
    rToMid.gain.value = 0.5;
    lToSide.gain.value = 0.5;
    rToSide.gain.value = -0.5;

    this.midGain = ctx.createGain();
    this.sideGain = ctx.createGain();
    this.midGain.gain.value = 1;
    this.sideGain.gain.value = 1;

    // Presence shelf on mid (helps “vocal” read when vocalAmt high)
    const midPresence = ctx.createBiquadFilter();
    midPresence.type = "peaking";
    midPresence.frequency.value = 2800;
    midPresence.Q.value = 0.9;
    midPresence.gain.value = 0;

    this.input.connect(split);
    split.connect(lToMid, 0);
    split.connect(rToMid, 1);
    split.connect(lToSide, 0);
    split.connect(rToSide, 1);

    const midSum = ctx.createGain();
    const sideSum = ctx.createGain();
    lToMid.connect(midSum);
    rToMid.connect(midSum);
    lToSide.connect(sideSum);
    rToSide.connect(sideSum);

    midSum.connect(this.midGain);
    this.midGain.connect(midPresence);

    // Encode mid/side back to L/R:
    // L = mid + side, R = mid - side
    const midToL = ctx.createGain();
    const midToR = ctx.createGain();
    const sideToL = ctx.createGain();
    const sideToR = ctx.createGain();
    midToL.gain.value = 1;
    midToR.gain.value = 1;
    sideToL.gain.value = 1;
    sideToR.gain.value = -1;

    midPresence.connect(midToL);
    midPresence.connect(midToR);
    sideSum.connect(this.sideGain);
    this.sideGain.connect(sideToL);
    this.sideGain.connect(sideToR);

    midToL.connect(merge, 0, 0);
    sideToL.connect(merge, 0, 0);
    midToR.connect(merge, 0, 1);
    sideToR.connect(merge, 0, 1);
    merge.connect(this.output);

    // stash presence for automation
    (this as unknown as { _presence: BiquadFilterNode })._presence = midPresence;
  }

  /** 0 = dry stereo balance, 1 = full instrumental (vocal removed). */
  setInstrumental(amount: number, when: number, immediate = false) {
    const a = Math.min(1, Math.max(0, amount));
    const mid = 1 - 0.92 * a;
    const side = 1 + 0.15 * a; // slight side lift so bed stays wide
    this.setGain(this.midGain.gain, mid, when, immediate);
    this.setGain(this.sideGain.gain, side, when, immediate);
    const presence = (this as unknown as { _presence: BiquadFilterNode })._presence;
    this.setGain(presence.gain, -3 * a, when, immediate);
  }

  /** 0 = dry, 1 = vocal focus (sides ducked, mid presence up). */
  setVocal(amount: number, when: number, immediate = false) {
    const a = Math.min(1, Math.max(0, amount));
    const mid = 1 + 0.1 * a;
    const side = 1 - 0.85 * a;
    this.setGain(this.midGain.gain, mid, when, immediate);
    this.setGain(this.sideGain.gain, side, when, immediate);
    const presence = (this as unknown as { _presence: BiquadFilterNode })._presence;
    this.setGain(presence.gain, 4.5 * a, when, immediate);
  }

  setDry(when: number, immediate = false) {
    this.setGain(this.midGain.gain, 1, when, immediate);
    this.setGain(this.sideGain.gain, 1, when, immediate);
    const presence = (this as unknown as { _presence: BiquadFilterNode })._presence;
    this.setGain(presence.gain, 0, when, immediate);
  }

  private setGain(param: AudioParam, value: number, when: number, immediate: boolean) {
    if (immediate) {
      param.cancelScheduledValues(when);
      param.setValueAtTime(value, when);
    } else {
      param.linearRampToValueAtTime(value, when + 0.04);
    }
  }

  disconnect() {
    try {
      this.input.disconnect();
      this.output.disconnect();
    } catch {
      /* ignore */
    }
  }
}
