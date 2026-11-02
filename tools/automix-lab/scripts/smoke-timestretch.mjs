/**
 * Smoke: pitch-preserving beatmatch stretch + downbeat phase slip.
 * Run: node scripts/smoke-timestretch.mjs
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const require = createRequire(import.meta.url);

function bundle(entry) {
  let esbuild;
  try {
    esbuild = require("esbuild");
  } catch {
    const dir = mkdtempSync(join(tmpdir(), "stretch-smoke-"));
    const out = join(dir, "out.mjs");
    const r = spawnSync(
      "npx",
      ["--yes", "esbuild", entry, "--bundle", "--platform=node", "--format=esm", `--outfile=${out}`],
      { cwd: root, encoding: "utf8" }
    );
    if (r.status !== 0) {
      console.error(r.stderr || r.stdout);
      process.exit(1);
    }
    return { dir, url: pathToFileURL(out).href };
  }
  const dir = mkdtempSync(join(tmpdir(), "stretch-smoke-"));
  const out = join(dir, "out.mjs");
  esbuild.buildSync({
    entryPoints: [entry],
    bundle: true,
    platform: "node",
    format: "esm",
    outfile: out,
  });
  return { dir, url: pathToFileURL(out).href };
}

const dsp = bundle(join(root, "src/dsp/timeStretch.ts"));
const analysis = bundle(join(root, "src/audio/analyzeTrack.ts"));
const plan = bundle(join(root, "src/audio/aiMixEngine.ts"));
const {
  timeStretchBuffer,
  beatmatchTransport,
  tempoPitchCompensationCents,
  tempoNeedsPitchLock,
} = await import(dsp.url);
const { estimateDownbeat } = await import(analysis.url);
const { alignBeatPhase, planAutomix } = await import(plan.url);

let failed = 0;
function check(name, cond, extra = "") {
  if (cond) console.log(`OK  ${name}${extra ? `\n      → ${extra}` : ""}`);
  else {
    console.error(`FAIL ${name}${extra ? `\n      → ${extra}` : ""}`);
    failed++;
  }
}

const cents = tempoPitchCompensationCents(1.06);
const expectCents = -1200 * Math.log2(1.06);
check(
  "compensation cents = -1200·log2(rate)",
  Math.abs(cents - expectCents) < 1e-6,
  `${cents.toFixed(2)}¢`
);
check("rate 1 → 0¢", tempoPitchCompensationCents(1) === 0);
check("pitch lock above ~7¢", tempoNeedsPitchLock(1.01) && !tempoNeedsPitchLock(1.001));

const locked = beatmatchTransport({ outgoing: 1.06, incoming: 0.97 }, 40, true, true);
check(
  "locked transport is rate 1, Camelot detune only",
  locked.rateA === 1 &&
    locked.rateB === 1 &&
    locked.detuneA === 0 &&
    locked.detuneB === 40,
  JSON.stringify(locked)
);
const open = beatmatchTransport({ outgoing: 1.06, incoming: 0.97 }, 40, false, false);
check(
  "unlocked keeps tempo rate and does not cancel it with detune",
  open.rateA === 1.06 && open.rateB === 0.97 && open.detuneB === 40 && open.detuneA === 0,
  JSON.stringify(open)
);

await import("web-audio-api/polyfill");
const sr = 44100;
const ctx = new globalThis.OfflineAudioContext(1, sr, sr);

function makeTone(seconds, hz, amp = 0.5) {
  const n = Math.floor(sr * seconds);
  const buf = ctx.createBuffer(1, n, sr);
  const d = buf.getChannelData(0);
  for (let i = 0; i < n; i++) d[i] = amp * Math.sin((2 * Math.PI * hz * i) / sr);
  return buf;
}

function makeDc(seconds, amp = 0.5) {
  const n = Math.floor(sr * seconds);
  const buf = ctx.createBuffer(1, n, sr);
  const d = buf.getChannelData(0);
  d.fill(amp);
  return buf;
}

function dominantHz(buffer) {
  const x = buffer.getChannelData(0);
  const minLag = Math.floor(sr / 520);
  const maxLag = Math.floor(sr / 200);
  const start = Math.floor(x.length * 0.35);
  const n = Math.min(Math.floor(sr * 0.4), x.length - maxLag - start - 1);
  let bestLag = minLag;
  let best = -Infinity;
  for (let lag = minLag; lag <= maxLag; lag++) {
    let c = 0;
    for (let i = 0; i < n; i += 2) c += x[start + i] * x[start + i + lag];
    if (c > best) {
      best = c;
      bestLag = lag;
    }
  }
  return sr / bestLag;
}

function meanRange(buffer, fromFrac, toFrac) {
  const x = buffer.getChannelData(0);
  const a = Math.floor(x.length * fromFrac);
  const b = Math.floor(x.length * toFrac);
  let s = 0;
  for (let i = a; i < b; i++) s += x[i];
  return s / Math.max(1, b - a);
}

const tone = makeTone(2, 440);
const t0 = performance.now();
const faster = timeStretchBuffer(tone, 1.12, undefined, ctx);
const slower = timeStretchBuffer(tone, 0.9, undefined, ctx);
const stretchMs = performance.now() - t0;
const hzFast = dominantHz(faster);
const hzSlow = dominantHz(slower);
check(
  "faster buffer is shorter",
  Math.abs(faster.duration * 1.12 - tone.duration) < 0.02,
  `out ${faster.duration.toFixed(3)}s`
);
check(
  "slower buffer is longer",
  Math.abs(slower.duration * 0.9 - tone.duration) < 0.02,
  `out ${slower.duration.toFixed(3)}s`
);
check(
  "pitch stays near 440 Hz when sped up",
  Math.abs(hzFast - 440) / 440 < 0.03 && Math.abs(hzFast - 440) < Math.abs(hzFast - 440 * 1.12),
  `${hzFast.toFixed(1)} Hz`
);
check(
  "pitch stays near 440 Hz when slowed",
  Math.abs(hzSlow - 440) / 440 < 0.03,
  `${hzSlow.toFixed(1)} Hz`
);

const dc = makeDc(1.2, 0.5);
const dcOut = timeStretchBuffer(dc, 1.08, undefined, ctx);
const head = meanRange(dcOut, 0, 0.012);
const body = meanRange(dcOut, 0.2, 0.7);
check("stretch does not fade in", head > 0.35, `head ${head.toFixed(3)}`);
check("stretch keeps level", Math.abs(body - 0.5) < 0.08, `body ${body.toFixed(3)}`);
console.log(`      stretch 2×2s in ${stretchMs.toFixed(0)}ms`);

const anaSr = 22050;
const anaCtx = new globalThis.OfflineAudioContext(1, anaSr, anaSr);
const clicks = anaCtx.createBuffer(1, Math.floor(anaSr * 10), anaSr);
const cd = clicks.getChannelData(0);
for (let t = 0.1; t < 9.8; t += 0.5) {
  const i0 = Math.floor(t * anaSr);
  for (let i = 0; i < 90 && i0 + i < cd.length; i++) {
    cd[i0 + i] += Math.sin((2 * Math.PI * 90 * i) / anaSr) * Math.exp(-i / 14);
  }
}
const grid = estimateDownbeat(cd, anaSr, 120);
const phaseErrSec = Math.min(
  Math.abs(grid.downbeatSec - 0.1),
  Math.abs(grid.downbeatSec - 0.1 + 0.5),
  Math.abs(grid.downbeatSec - 0.1 - 0.5)
);
check(
  "click grid phase near 0.10s",
  grid.confidence >= 0.62 && phaseErrSec < 0.02,
  `downbeat ${grid.downbeatSec.toFixed(3)}s conf ${grid.confidence.toFixed(2)} err ${phaseErrSec.toFixed(3)}s`
);

let noisePeak = 0;
for (let trial = 0; trial < 4; trial++) {
  const noise = anaCtx.createBuffer(1, Math.floor(anaSr * 8), anaSr);
  const nd = noise.getChannelData(0);
  for (let i = 0; i < nd.length; i++) nd[i] = Math.random() * 2 - 1;
  noisePeak = Math.max(noisePeak, estimateDownbeat(nd, anaSr, 120).confidence);
}
check("noise grid is low confidence", noisePeak < 0.45, `peak conf ${noisePeak.toFixed(2)}`);

function frac(sec, downbeat, bpm) {
  const beat = 60 / bpm;
  let x = (sec - downbeat) / beat;
  x -= Math.floor(x);
  if (x < 0) x += 1;
  return x;
}
function wrapHalf(delta) {
  let x = delta - Math.floor(delta);
  if (x > 0.5) x -= 1;
  return x;
}

const slipped = alignBeatPhase({
  cueA: 10,
  cueB: 8.15,
  bpmA: 120,
  bpmB: 120,
  downbeatA: 0,
  downbeatB: 0,
  confidenceA: 0.9,
  confidenceB: 0.9,
  bpmConfidenceA: 0.9,
  bpmConfidenceB: 0.9,
  limitA: [0, 100],
  limitB: [0, 100],
});
const errBefore = Math.abs(wrapHalf(frac(10, 0, 120) - frac(8.15, 0, 120)));
const errAfter = Math.abs(wrapHalf(frac(slipped.cueA, 0, 120) - frac(slipped.cueB, 0, 120)));
check("phase slip reduces error", slipped.nudged && errAfter < 0.02 && errAfter < errBefore, slipped.note ?? "");
check(
  "phase slip stays within half a beat",
  Math.abs(slipped.deltaA) <= 0.25 + 1e-6 && Math.abs(slipped.deltaB) <= 0.25 + 1e-6,
  `ΔA ${slipped.deltaA.toFixed(3)} ΔB ${slipped.deltaB.toFixed(3)}`
);
const shy = alignBeatPhase({
  cueA: 10,
  cueB: 8.15,
  bpmA: 120,
  bpmB: 120,
  downbeatA: 0,
  downbeatB: 0,
  confidenceA: 0.2,
  confidenceB: 0.9,
  limitA: [0, 100],
  limitB: [0, 100],
});
check("low confidence does not move cues", !shy.nudged && shy.cueA === 10 && shy.cueB === 8.15);

const capped = alignBeatPhase({
  cueA: 10,
  cueB: 8.25,
  bpmA: 120,
  bpmB: 120,
  downbeatA: 0,
  downbeatB: 0,
  confidenceA: 0.95,
  confidenceB: 0.95,
  bpmConfidenceA: 0.9,
  bpmConfidenceB: 0.9,
  limitA: [10, 10],
  limitB: [0, 30],
});
check(
  "one-sided slip still caps at half a beat",
  capped.nudged &&
    Math.abs(capped.deltaA) < 1e-6 &&
    Math.abs(capped.deltaB) <= 0.25 + 1e-6 &&
    Math.abs(wrapHalf(frac(capped.cueA, 0, 120) - frac(capped.cueB, 0, 120))) < 0.05,
  capped.note ?? ""
);

function profile(partial) {
  return {
    name: partial.name ?? "t",
    durationSec: 200,
    bpm: partial.bpm,
    bpmConfidence: 0.85,
    camelotKey: "8A",
    keyConfidence: 0.8,
    energy: Array.from({ length: 80 }, () => 0.55),
    vocalPresence: Array.from({ length: 80 }, () => 0.5),
    mixInSec: partial.mixInSec ?? 10,
    mixOutSec: partial.mixOutSec ?? 150,
    hasFadeOut: false,
    endsInSilence: false,
    tempoStability: 0.85,
    downbeatSec: partial.downbeatSec ?? 0,
    downbeatConfidence: partial.downbeatConfidence ?? 0,
    reason: "smoke",
  };
}

const a = profile({ name: "A", bpm: 120, mixOutSec: 150, downbeatSec: 0 });
const bLow = profile({ name: "B", bpm: 122, mixInSec: 10, downbeatSec: 0.2, downbeatConfidence: 0.1 });
const bHigh = profile({
  name: "B",
  bpm: 122,
  mixInSec: 10,
  downbeatSec: 0.2,
  downbeatConfidence: 0.9,
});
a.downbeatConfidence = 0.9;
const plain = planAutomix({ ...a, downbeatConfidence: 0.1 }, bLow);
const phased = planAutomix(a, bHigh);
const errPlain = Math.abs(
  wrapHalf(frac(plain.params.cueASec, 0, 120) - frac(plain.params.cueBSec, 0.2, 122))
);
const errPhased = Math.abs(
  wrapHalf(frac(phased.params.cueASec, 0, 120) - frac(phased.params.cueBSec, 0.2, 122))
);
check(
  "planAutomix nudges cues when phase confidence is high",
  phased.processing.some((line) => line.includes("phase align")) &&
    errPhased + 0.02 < errPlain &&
    Math.abs(phased.params.cueASec - plain.params.cueASec) <= 0.26 &&
    Math.abs(phased.params.cueBSec - plain.params.cueBSec) <= 60 / 122 / 2 + 0.01,
  `plain err ${errPlain.toFixed(3)} → ${errPhased.toFixed(3)} · A ${plain.params.cueASec.toFixed(2)}→${phased.params.cueASec.toFixed(2)} B ${plain.params.cueBSec.toFixed(2)}→${phased.params.cueBSec.toFixed(2)}`
);

rmSync(dsp.dir, { recursive: true, force: true });
rmSync(analysis.dir, { recursive: true, force: true });
rmSync(plan.dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} timestretch smoke(s) failed`);
  process.exit(1);
}
console.log("\nAll timestretch smokes passed.");
