/** Offline BPM regression tests. No network or source audio is required.
 * Run: node scripts/test-tempo.mjs
 * Optional local reference pair (requires ffmpeg):
 * node scripts/test-tempo.mjs --pair .ym-cache/wave-a-138790032.mp3 .ym-cache/wave-b-103251124.mp3
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = fileURLToPath(new URL("..", import.meta.url));
const bundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/audio/analyzeTrack.ts", import.meta.url))],
  bundle: true, platform: "node", format: "esm", write: false, logLevel: "silent",
});
const { estimateBPMFromSamples: estimate } = await import(
  `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].contents).toString("base64")}`
);

function generator(seed = 341) {
  let state = seed;
  return () => ((state = (Math.imul(state, 1664525) + 1013904223) >>> 0) / 2 ** 32);
}

function makeTrack(bpm, sampleRate, seconds, options = {}) {
  const samples = new Float32Array(Math.floor(sampleRate * seconds));
  const random = generator();
  const pulse = (time, frequency, amplitude, duration) => {
    const start = Math.round(time * sampleRate);
    for (let j = 0; j < duration * sampleRate && start + j < samples.length; j++) {
      if (start + j >= 0) samples[start + j] += amplitude * Math.exp(-j / (duration * sampleRate * 0.25)) * Math.sin(2 * Math.PI * frequency * j / sampleRate);
    }
  };
  for (let t = options.phase ?? 0.173, beat = 0; t < seconds; t += 60 / bpm, beat++) {
    if (options.silentEnds && (t < seconds * 0.17 || t > seconds * 0.83)) continue;
    pulse(t, 600, 0.55, 0.045);
    pulse(t, 70, 0.3, 0.11);
    if (beat % 2) pulse(t, 1800, 0.18, 0.035);
  }
  if (options.irregularBass) {
    for (let t = 0.07; t < seconds; t += 0.12 + random() * 0.24) pulse(t, 55, 0.4, 0.13);
  }
  if (options.noise) {
    for (let i = 0; i < samples.length; i++) samples[i] += (random() - 0.5) * 0.04;
  }
  return samples;
}

function near(label, actual, target, tolerance) {
  assert.ok(Number.isFinite(actual) && Math.abs(actual - target) <= tolerance,
    `${label}: expected ${target} ± ${tolerance}, got ${actual}`);
}
function check(label, samples, sr, bpm, tolerance = 0.8) {
  const result = estimate(samples, sr);
  near(label, result.bpm, bpm, tolerance);
  assert.ok(Number.isFinite(result.confidence) && result.confidence >= 0 && result.confidence <= 1);
  return result;
}

// Includes fractional hop duration at 11025/22050 Hz and tempos that once
// collapsed onto the same rounded 10 ms lag.
for (const sr of [8000, 11025, 22050, 44100]) {
  for (const bpm of [90, 100, 118.4, 121, 122, 124, 125, 127.3, 140, 155]) {
    check(`${sr} Hz / ${bpm} BPM`, makeTrack(bpm, sr, 24, { noise: true }), sr, bpm);
  }
}
// A competing bass pulse train plus irregular bass masks the 125.2 BPM
// mid-band beat in the full-band envelope. Without the band path this
// deterministic fixture selects approximately 130 BPM instead.
function maskedMidBeat() {
  const sr = 22050;
  const samples = new Float32Array(sr * 32);
  const random = generator(12345);
  const pulse = (time, frequency, amplitude, duration) => {
    const start = Math.round(time * sr);
    for (let j = 0; j < duration * sr && start + j < samples.length; j++) {
      samples[start + j] += amplitude * Math.exp(-j / (duration * sr * 0.25)) * Math.sin(2 * Math.PI * frequency * j / sr);
    }
  };
  for (let t = 0.173; t < 32; t += 60 / 125.2) pulse(t, 600, 0.4, 0.04);
  for (let t = 0.08; t < 32; t += 60 / 130) pulse(t, 35, 0.4, 0.12);
  for (let t = 0.07; t < 32; t += 0.12 + random() * 0.24) pulse(t, 35, 0.4, 0.13);
  return samples;
}
check("clear mid-band beat with masked full-band peak", maskedMidBeat(), 22050, 125.2, 0.8);
check("silent intro/outro", makeTrack(124.3, 22050, 36, { silentEnds: true, phase: 0.31 }), 22050, 124.3);
check("irregular bass under clear mid-band beat", makeTrack(125.2, 22050, 40, { irregularBass: true }), 22050, 125.2, 1);
// Octave ambiguity is intentional: this alternating-accent example is heard
// as half time by the existing heuristic; do not silently assert 170 BPM.
check("half-time ambiguity", makeTrack(170, 22050, 24, { noise: true }), 22050, 85, 1);
for (const [label, samples, sr] of [
  ["empty", new Float32Array(), 22050],
  ["short", new Float32Array(100), 22050],
  ["silence", new Float32Array(22050 * 10), 22050],
  ["invalid rate", new Float32Array(1000), 0],
  ["non-finite samples", Float32Array.from([NaN, ...new Array(999).fill(0)]), 22050],
]) assert.deepEqual(estimate(samples, sr), { bpm: 120, confidence: 0.1 }, label);
const random = generator();
const noise = Float32Array.from({ length: 22050 * 20 }, () => random() * 2 - 1);
const noiseResult = estimate(noise, 22050);
assert.ok(noiseResult.confidence < 0.5, `noise confidence: ${noiseResult.confidence}`);
console.log("Synthetic BPM regressions: passed");

if (process.argv.length > 2) {
  assert.equal(process.argv[2], "--pair", "expected --pair <More> <RASA>");
  assert.equal(process.argv.length, 5, "expected exactly two local file paths");
  for (const [path, target] of [[process.argv[3], 122], [process.argv[4], 125]]) {
    const decoded = spawnSync("ffmpeg", ["-v", "error", "-i", path, "-ac", "1", "-ar", "22050", "-f", "f32le", "pipe:1"], { maxBuffer: 80 * 1024 * 1024 });
    assert.equal(decoded.status, 0, `local ffmpeg decode failed: ${decoded.stderr}`);
    // Copy to ensure Float32Array alignment and avoid any file writes.
    const samples = new Float32Array(decoded.stdout.byteLength / 4);
    for (let i = 0; i < samples.length; i++) samples[i] = decoded.stdout.readFloatLE(i * 4);
    const result = check(path, samples, 22050, target, 2);
    console.log(`${path}: ${result.bpm} BPM, confidence ${result.confidence.toFixed(2)} (approximate reference ${target})`);
  }
}
