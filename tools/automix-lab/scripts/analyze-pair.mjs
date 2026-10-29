/**
 * Offline analyze two WAVs + print TZ plan (no browser).
 * Usage: node scripts/analyze-pair.mjs /tmp/a.wav /tmp/b.wav
 */
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const root = new URL("..", import.meta.url).pathname;
const dir = mkdtempSync(join(tmpdir(), "tz-pair-"));

function bundle(entry, outName) {
  const out = join(dir, outName);
  const r = spawnSync(
    "npx",
    ["--yes", "esbuild", entry, "--bundle", "--platform=node", "--format=esm", `--outfile=${out}`],
    { cwd: root, encoding: "utf8" }
  );
  if (r.status !== 0) {
    console.error(r.stderr || r.stdout);
    process.exit(1);
  }
  return out;
}

const analyzeOut = bundle("src/audio/analyzeTrack.ts", "analyze.mjs");
const keyOut = bundle("src/audio/keyCamelot.ts", "key.mjs");
const aimixOut = bundle("src/audio/aiMixEngine.ts", "aimix.mjs");

const { estimateBPMFromSamples } = await import(pathToFileURL(analyzeOut).href);
const { computeChroma, estimateCamelotKey } = await import(pathToFileURL(keyOut).href);
const { planAutomix } = await import(pathToFileURL(aimixOut).href);

function decodeWav(path) {
  const buf = readFileSync(path);
  if (buf.toString("ascii", 0, 4) !== "RIFF") throw new Error("not wav: " + path);
  let offset = 12;
  let sampleRate = 44100;
  let channels = 2;
  let bits = 16;
  let dataOffset = 0;
  let dataSize = 0;
  while (offset + 8 <= buf.length) {
    const id = buf.toString("ascii", offset, offset + 4);
    const size = buf.readUInt32LE(offset + 4);
    if (id === "fmt ") {
      channels = buf.readUInt16LE(offset + 10);
      sampleRate = buf.readUInt32LE(offset + 12);
      bits = buf.readUInt16LE(offset + 22);
    } else if (id === "data") {
      dataOffset = offset + 8;
      dataSize = size;
      break;
    }
    offset += 8 + size + (size % 2);
  }
  if (!dataOffset) throw new Error("no data chunk");
  const nFrames = Math.floor(dataSize / (channels * (bits / 8)));
  const mono = new Float32Array(nFrames);
  if (bits !== 16) throw new Error("bits=" + bits);
  for (let i = 0; i < nFrames; i++) {
    let s = 0;
    for (let c = 0; c < channels; c++) {
      s += buf.readInt16LE(dataOffset + (i * channels + c) * 2) / 32768;
    }
    mono[i] = s / channels;
  }
  return {
    samples: mono,
    sampleRate,
    durationSec: nFrames / sampleRate,
    name: path.split("/").pop(),
  };
}

function downsample(samples, fromRate, toRate) {
  if (toRate >= fromRate) return samples;
  const ratio = fromRate / toRate;
  const n = Math.floor(samples.length / ratio);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = samples[Math.floor(i * ratio)] ?? 0;
  return out;
}

function energyCurve(samples, sampleRate) {
  const hop = Math.max(1, Math.floor(sampleRate * 0.25));
  const curve = [];
  for (let i = 0; i + hop <= samples.length; i += hop) {
    let sum = 0;
    for (let j = 0; j < hop; j++) {
      const v = samples[i + j];
      sum += v * v;
    }
    curve.push(Math.sqrt(sum / hop));
  }
  const peak = Math.max(...curve, 1e-9);
  return curve.map((v) => Math.min(1, v / peak));
}

function vocalCurve(samples, sampleRate, energy) {
  const rc = 1 / (2 * Math.PI * 300);
  const dt = 1 / sampleRate;
  const alpha = rc / (rc + dt);
  let prevX = 0;
  let prevY = 0;
  const hop = Math.max(1, Math.floor(sampleRate * 0.25));
  const out = [];
  for (let i = 0; i + hop <= samples.length; i += hop) {
    let sum = 0;
    for (let j = 0; j < hop; j++) {
      const x = samples[i + j];
      const y = alpha * (prevY + x - prevX);
      prevX = x;
      prevY = y;
      sum += y * y;
    }
    out.push(Math.sqrt(sum / hop));
  }
  const peak = Math.max(...out, 1e-9);
  const norm = out.map((v) => Math.min(1, v / peak));
  const n = Math.min(norm.length, energy.length);
  return Array.from({ length: n }, (_, i) => norm[i] * 0.65 + energy[i] * 0.35);
}

function meanSlice(values, from, to) {
  const a = Math.max(0, Math.floor(from));
  const b = Math.min(values.length, Math.ceil(to));
  if (b <= a) return 0;
  let s = 0;
  for (let i = a; i < b; i++) s += values[i];
  return s / (b - a);
}

function detectMixOut(energy, vocal, duration) {
  const n = energy.length;
  const hop = 0.25;
  const minTailSec = duration > 150 ? 32 : duration > 100 ? 24 : 16;
  const fallback = Math.max(0, duration - minTailSec);
  if (n < 8) return { mixOut: fallback, fade: false, silent: false };
  const silent = meanSlice(energy, n * 0.92, n) < 0.08;
  const fade = meanSlice(energy, n * 0.7, n * 0.85) > meanSlice(energy, n * 0.9, n) * 1.35;
  const bodyMean = meanSlice(energy, n * 0.2, n * 0.6);
  const vocalBody = meanSlice(vocal, n * 0.2, n * 0.6);
  const searchStart = Math.floor(n * 0.65);
  const searchEnd = Math.max(searchStart + 4, Math.floor((duration - minTailSec) / hop));
  let bestIdx = Math.floor(fallback / hop);
  let bestScore = -1;
  for (let i = searchStart; i < Math.min(n - 4, searchEnd); i++) {
    const localE = meanSlice(energy, i, i + 6);
    const localV = meanSlice(vocal, i, i + 6);
    const nextV = meanSlice(vocal, i + 4, Math.min(n, i + 12));
    const vocalDrop = vocalBody > 0.2 && localV < vocalBody * 0.6 && nextV <= localV * 1.1;
    const softOutro = localE < bodyMean * 0.8;
    const score =
      (vocalDrop ? 2.5 : 0) + (softOutro ? 1 : 0) + (1 - localV) * 0.8 + Math.min(1, localE) * 0.3;
    if (score > bestScore) {
      bestScore = score;
      bestIdx = i;
    }
  }
  let mixOut = bestIdx * hop;
  const earliest = duration * 0.7;
  const latest = Math.max(earliest, duration - minTailSec);
  mixOut = Math.min(latest, Math.max(earliest, mixOut));
  return { mixOut, fade, silent };
}

function detectMixIn(energy, vocal, duration) {
  const hop = 0.25;
  const n = energy.length;
  if (n < 8 || duration < 90) return 0;
  const headEnd = Math.min(n, Math.floor(Math.min(48, duration * 0.25) / hop));
  const body = meanSlice(energy, n * 0.25, n * 0.5);
  for (let i = 2; i < headEnd - 4; i++) {
    const prev = meanSlice(energy, 0, i);
    const next = meanSlice(energy, i, i + 6);
    const vNext = meanSlice(vocal, i, i + 6);
    if (next > Math.max(0.2, body * 0.55) && next > prev * 1.35 && (vNext > 0.25 || next > 0.35)) {
      return Math.min(duration * 0.25, i * hop);
    }
  }
  return Math.min(32, duration > 180 ? 16 : 8);
}

function analyzeFile(path) {
  console.log("decode", path);
  const wav = decodeWav(path);
  const analysisRate = 22050;
  const mono = downsample(wav.samples, wav.sampleRate, analysisRate);
  const energy = energyCurve(mono, analysisRate);
  const vocal = vocalCurve(mono, analysisRate, energy);
  const tempo = estimateBPMFromSamples(mono, analysisRate);
  const chroma = computeChroma(mono, analysisRate);
  const key = estimateCamelotKey(chroma);
  const out = detectMixOut(energy, vocal, wav.durationSec);
  const mixIn = detectMixIn(energy, vocal, wav.durationSec);
  return {
    name: wav.name,
    durationSec: wav.durationSec,
    bpm: tempo.bpm,
    bpmConfidence: tempo.confidence,
    camelotKey: key.camelot,
    keyConfidence: key.confidence,
    energy,
    vocalPresence: vocal,
    mixInSec: mixIn,
    mixOutSec: out.mixOut,
    hasFadeOut: out.fade,
    endsInSilence: out.silent,
    tempoStability: 0.75,
    reason: `BPM ${tempo.bpm} · Key ${key.camelot ?? "?"} · mixOut ${out.mixOut.toFixed(1)}s`,
  };
}

const aPath = process.argv[2] || "/tmp/track-a-nkeeei.wav";
const bPath = process.argv[3] || "/tmp/track-b-kai-angel.wav";
const a = analyzeFile(aPath);
const b = analyzeFile(bPath);
const plan = planAutomix(a, b);

console.log("\n=== A ===");
console.log(a.reason, `dur=${a.durationSec.toFixed(1)} mixIn=${a.mixInSec.toFixed(1)}`);
console.log("=== B ===");
console.log(b.reason, `dur=${b.durationSec.toFixed(1)} mixIn=${b.mixInSec.toFixed(1)}`);
console.log("\n=== planAutomix (TZ §2.4) ===");
console.log("type:", plan.transitionType);
console.log("story:", plan.story);
console.log("beatmatched:", plan.beatmatched);
console.log(
  "rates:",
  plan.params.rateA,
  plan.params.rateB,
  "pitchB¢",
  plan.params.pitchCentsB
);
console.log(
  "cues:",
  plan.params.cueASec,
  "→",
  plan.params.cueBSec,
  "blend",
  plan.params.blendDurationSec
);
console.log("processing:");
for (const line of plan.processing) console.log(" -", line);

rmSync(dir, { recursive: true, force: true });
