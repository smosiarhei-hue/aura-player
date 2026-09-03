import type { Genre } from "../types";

export interface DemoSpec {
  id: string;
  title: string;
  artist: string;
  bpm: number;
  root: number; // midi
  minor: boolean;
  style: "house" | "techno" | "hiphop" | "dnb" | "pop" | "lofi";
  genre: Genre;
  bars: number;
  seed: number;
  color: string;
  color2: string;
}

export const DEMO_SPECS: DemoSpec[] = [
  { id: "demo-1", title: "Neon Drive", artist: "Vela Nova", bpm: 124, root: 57, minor: true, style: "house", genre: "House", bars: 32, seed: 11, color: "#ff5f8f", color2: "#7c3aed" },
  { id: "demo-2", title: "Deep Current", artist: "Marlowe", bpm: 122, root: 52, minor: true, style: "house", genre: "House", bars: 32, seed: 23, color: "#22d3ee", color2: "#1d4ed8" },
  { id: "demo-3", title: "Warehouse 03", artist: "KRVT", bpm: 132, root: 50, minor: true, style: "techno", genre: "Techno", bars: 32, seed: 37, color: "#a3e635", color2: "#065f46" },
  { id: "demo-4", title: "Sunset Radio", artist: "Aurelia", bpm: 112, root: 60, minor: false, style: "pop", genre: "Pop", bars: 28, seed: 41, color: "#fbbf24", color2: "#f43f5e" },
  { id: "demo-5", title: "Late Tape", artist: "Lo Kaz", bpm: 86, root: 55, minor: true, style: "lofi", genre: "Lo-Fi", bars: 20, seed: 53, color: "#c084fc", color2: "#312e81" },
  { id: "demo-6", title: "Concrete Flow", artist: "Deka", bpm: 92, root: 53, minor: true, style: "hiphop", genre: "Hip-Hop", bars: 22, seed: 67, color: "#fb923c", color2: "#7f1d1d" },
  { id: "demo-7", title: "Liquid Sky", artist: "Nyx", bpm: 174, root: 57, minor: true, style: "dnb", genre: "Drum & Bass", bars: 48, seed: 71, color: "#38bdf8", color2: "#0f172a" },
  { id: "demo-8", title: "Glasshouse", artist: "Vela Nova", bpm: 126, root: 62, minor: false, style: "house", genre: "House", bars: 32, seed: 89, color: "#f472b6", color2: "#0ea5e9" },
];

function rng(seed: number) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13; s >>>= 0;
    s ^= s >> 17;
    s ^= s << 5; s >>>= 0;
    return (s >>> 0) / 4294967296;
  };
}

const midiHz = (m: number) => 440 * Math.pow(2, (m - 69) / 12);

function makeNoise(ctx: BaseAudioContext, seconds: number, rand: () => number) {
  const buf = ctx.createBuffer(1, Math.floor(ctx.sampleRate * seconds), ctx.sampleRate);
  const d = buf.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = rand() * 2 - 1;
  return buf;
}

function softClipCurve() {
  const n = 1024;
  const c = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const x = (i / (n - 1)) * 2 - 1;
    c[i] = Math.tanh(x * 1.6) / Math.tanh(1.6);
  }
  return c;
}

export async function renderDemo(spec: DemoSpec): Promise<AudioBuffer> {
  const sr = 44100;
  const beat = 60 / spec.bpm;
  const bar = beat * 4;
  const total = spec.bars * bar + 1.5;
  const ctx = new OfflineAudioContext(2, Math.ceil(total * sr), sr);
  const rand = rng(spec.seed);

  const master = ctx.createGain();
  master.gain.value = 0.8;
  const shaper = ctx.createWaveShaper();
  shaper.curve = softClipCurve();
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = -12;
  comp.ratio.value = 4;
  comp.attack.value = 0.005;
  comp.release.value = 0.15;
  master.connect(comp);
  comp.connect(shaper);
  shaper.connect(ctx.destination);

  const drumBus = ctx.createGain();
  const musicBus = ctx.createGain();
  drumBus.connect(master);
  musicBus.connect(master);

  const noise = makeNoise(ctx, 1, rand);
  const scale = spec.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11];
  const progression = spec.minor ? [0, 5, 2, 6] : [0, 3, 4, 5]; // ступени
  const intro = spec.style === "dnb" ? 8 : 4;
  const outro = spec.style === "dnb" ? 8 : 4;
  const main0 = intro;
  const main1 = spec.bars - outro;

  const kick = (t: number, vel = 1) => {
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.type = "sine";
    const f0 = spec.style === "techno" ? 170 : spec.style === "hiphop" || spec.style === "lofi" ? 120 : 150;
    o.frequency.setValueAtTime(f0, t);
    o.frequency.exponentialRampToValueAtTime(spec.style === "dnb" ? 55 : 42, t + 0.09);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(1.1 * vel, t + 0.004);
    g.gain.exponentialRampToValueAtTime(0.0001, t + (spec.style === "techno" ? 0.42 : 0.32));
    o.connect(g); g.connect(drumBus);
    o.start(t); o.stop(t + 0.5);
  };
  const snare = (t: number, vel = 1) => {
    const s = ctx.createBufferSource();
    s.buffer = noise;
    const bp = ctx.createBiquadFilter();
    bp.type = "bandpass"; bp.frequency.value = spec.style === "lofi" ? 1200 : 1900; bp.Q.value = 0.8;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.75 * vel, t);
    g.gain.exponentialRampToValueAtTime(0.001, t + 0.18);
    s.connect(bp); bp.connect(g); g.connect(drumBus);
    s.start(t); s.stop(t + 0.25);
    // тело
    const o = ctx.createOscillator();
    o.frequency.setValueAtTime(220, t); o.frequency.exponentialRampToValueAtTime(140, t + 0.06);
    const g2 = ctx.createGain();
    g2.gain.setValueAtTime(0.5 * vel, t); g2.gain.exponentialRampToValueAtTime(0.001, t + 0.12);
    o.connect(g2); g2.connect(drumBus); o.start(t); o.stop(t + 0.15);
  };
  const hat = (t: number, open = false, vel = 1) => {
    const s = ctx.createBufferSource();
    s.buffer = noise;
    const hp = ctx.createBiquadFilter();
    hp.type = "highpass"; hp.frequency.value = 7500;
    const g = ctx.createGain();
    const len = open ? 0.22 : 0.05;
    g.gain.setValueAtTime(0.28 * vel, t);
    g.gain.exponentialRampToValueAtTime(0.001, t + len);
    s.connect(hp); hp.connect(g); g.connect(drumBus);
    s.start(t); s.stop(t + len + 0.02);
  };
  const bass = (t: number, midi: number, len: number, vel = 1) => {
    const o = ctx.createOscillator();
    o.type = spec.style === "hiphop" || spec.style === "lofi" ? "sine" : spec.style === "dnb" ? "sawtooth" : "sawtooth";
    o.frequency.value = midiHz(midi);
    const lp = ctx.createBiquadFilter();
    lp.type = "lowpass";
    lp.frequency.setValueAtTime(spec.style === "techno" ? 900 : 650, t);
    lp.frequency.exponentialRampToValueAtTime(140, t + len);
    lp.Q.value = 4;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(0.55 * vel, t + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t + len);
    o.connect(lp); lp.connect(g); g.connect(musicBus);
    o.start(t); o.stop(t + len + 0.02);
  };
  const chord = (t: number, degree: number, len: number, vel = 1) => {
    const notes = [0, 2, 4].map((k) => spec.root + 12 + scale[(degree + k) % 7] + 12 * Math.floor((degree + k) / 7));
    const lp = ctx.createBiquadFilter();
    lp.type = "lowpass";
    lp.frequency.setValueAtTime(spec.style === "lofi" ? 900 : 1800, t);
    lp.frequency.exponentialRampToValueAtTime(spec.style === "lofi" ? 500 : 900, t + len);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(0.16 * vel, t + (spec.style === "house" ? 0.01 : 0.15));
    g.gain.setValueAtTime(0.16 * vel, t + len * 0.6);
    g.gain.exponentialRampToValueAtTime(0.0001, t + len);
    lp.connect(g); g.connect(musicBus);
    notes.forEach((m, i) => {
      for (const det of [-6, 6]) {
        const o = ctx.createOscillator();
        o.type = spec.style === "lofi" ? "triangle" : "sawtooth";
        o.frequency.value = midiHz(m);
        o.detune.value = det + (i - 1) * 3;
        o.connect(lp);
        o.start(t); o.stop(t + len + 0.05);
      }
    });
  };
  const arp = (t: number, midi: number, len: number, vel = 1) => {
    const o = ctx.createOscillator();
    o.type = "square";
    o.frequency.value = midiHz(midi);
    const lp = ctx.createBiquadFilter();
    lp.type = "lowpass"; lp.frequency.value = 3200;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(0.09 * vel, t + 0.005);
    g.gain.exponentialRampToValueAtTime(0.0001, t + len);
    o.connect(lp); lp.connect(g); g.connect(musicBus);
    o.start(t); o.stop(t + len + 0.02);
  };

  const bassPattern = Array.from({ length: 8 }, () => (rand() < 0.35 ? 12 : rand() < 0.2 ? 7 : 0));
  const arpPattern = Array.from({ length: 16 }, () => Math.floor(rand() * 5));

  for (let b = 0; b < spec.bars; b++) {
    const t0 = b * bar;
    const inMain = b >= main0 && b < main1;
    const inIntro = b < main0;
    const inOutro = b >= main1;
    const degree = progression[Math.floor(b / 2) % 4];
    const bassRoot = spec.root - 12 + scale[degree % 7];
    const fadeOutro = inOutro ? 1 - (b - main1) / outro : 1;

    for (let s = 0; s < 16; s++) {
      const t = t0 + s * (beat / 4);
      const onBeat = s % 4 === 0;
      const beatIdx = Math.floor(s / 4);
      const offBeat = s % 4 === 2;

      // Ударные
      const drumsOn = inMain || (inOutro && b < spec.bars - 1) || (inIntro && b >= main0 - 2);
      if (drumsOn) {
        switch (spec.style) {
          case "house":
          case "techno":
            if (onBeat) kick(t);
            if (beatIdx === 1 || beatIdx === 3) { if (onBeat) snare(t, spec.style === "techno" ? 0.6 : 0.9); }
            if (s % 2 === 0) hat(t, offBeat && spec.style === "house", offBeat ? 0.9 : 0.5);
            break;
          case "pop":
            if (s === 0 || s === 8 || s === 10) kick(t);
            if (s === 4 || s === 12) snare(t);
            if (s % 2 === 0) hat(t, false, s % 4 === 0 ? 0.8 : 0.5);
            break;
          case "hiphop":
            if (s === 0 || s === 7 || s === 10) kick(t);
            if (s === 4 || s === 12) snare(t);
            if (s % 2 === 0 || rand() < 0.15) hat(t, false, 0.6);
            break;
          case "lofi":
            if (s === 0 || s === 10) kick(t, 0.8);
            if (s === 4 || s === 12) snare(t, 0.7);
            if (s % 4 === 2) hat(t, false, 0.5);
            break;
          case "dnb":
            if (s === 0 || s === 10) kick(t);
            if (s === 4 || s === 12) snare(t);
            if (s % 2 === 0) hat(t, false, 0.55);
            break;
        }
      } else if (inIntro && s % 4 === 2) {
        hat(t, false, 0.5);
      }

      // Бас
      if ((inMain || inOutro) && s % 2 === 0) {
        const step = bassPattern[s / 2];
        const play = spec.style === "lofi" || spec.style === "hiphop" ? s === 0 || s === 6 || s === 10 : spec.style === "techno" ? offBeat || onBeat : true;
        if (play) bass(t, bassRoot + step, spec.style === "techno" ? beat * 0.22 : beat * 0.45, fadeOutro);
      }

      // Арпеджио (pop / dnb / house-верх)
      if (inMain && (spec.style === "pop" || spec.style === "dnb" || (spec.style === "house" && b % 8 >= 4))) {
        if (s % 2 === 0 || spec.style === "dnb") {
          const m = spec.root + 24 + scale[(degree + arpPattern[s]) % 7];
          arp(t, m, beat / 4, 0.8);
        }
      }
    }

    // Аккорды
    const chordOn = inIntro || inMain || inOutro;
    if (chordOn) {
      const vel = inIntro ? 0.7 : inOutro ? fadeOutro * 0.8 : 1;
      if (spec.style === "house" || spec.style === "pop") {
        [1, 2.5].forEach((bt) => chord(t0 + bt * beat, degree, beat * 0.6, vel));
      } else {
        chord(t0, degree, bar * 0.95, vel);
      }
    }
  }

  return ctx.startRendering();
}
