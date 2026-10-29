/**
 * Smoke: mashup envelopes must be continuous (no audible steps at segment joins).
 * Run: node scripts/smoke-envelope-smoothness.mjs
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
    const dir = mkdtempSync(join(tmpdir(), "env-smoke-"));
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
  const dir = mkdtempSync(join(tmpdir(), "env-smoke-"));
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

const envBundle = bundle(join(root, "src/audio/envelopes.ts"));
const stemBundle = bundle(join(root, "src/dsp/stemEnvelopes.ts"));
const { volumesAt, bassGainDbAt, defaultParams } = await import(envBundle.url);
const { stemFxAt } = await import(stemBundle.url);

function maxJump(samples) {
  let m = 0;
  for (let i = 1; i < samples.length; i++) m = Math.max(m, Math.abs(samples[i] - samples[i - 1]));
  return m;
}

const params = defaultParams();
params.dsp.mashupMode = "vocalSwap";
params.dsp.instrAPeak = 0.85;
params.dsp.instrAAt = 0.12;
params.dsp.instrBPeak = 0.75;
params.dsp.instrBUntil = 0.35;
params.dsp.vocalBAt = 0.35;
params.outgoingVolumeHold = 0.42;
params.handoffAt = 0.55;
params.bassSwapAt = 0.22;
params.bassDepth = 1.1;

const N = 401;
const volsOut = [];
const volsIn = [];
const bassOut = [];
const bassIn = [];
const instrB = [];
for (let i = 0; i < N; i++) {
  const p = i / (N - 1);
  const v = volumesAt(p, params);
  const b = bassGainDbAt(p, params);
  const fx = stemFxAt(p, params);
  volsOut.push(v.outgoing);
  volsIn.push(v.incoming);
  bassOut.push(b.outgoing);
  bassIn.push(b.incoming);
  instrB.push(fx.instrumentalB);
}

// At 400 steps across the blend, per-step jumps must stay tiny.
const limVol = 0.045; // invite rise is intentionally musical; joins are checked separately
const limBass = 0.55; // dB per step
const limStem = 0.04;
const checks = [
  ["volA", maxJump(volsOut), limVol],
  ["volB", maxJump(volsIn), limVol],
  ["bassA", maxJump(bassOut), limBass],
  ["bassB", maxJump(bassIn), limBass],
  ["instrB", maxJump(instrB), limStem],
];

// Explicit segment joins (hold / handoff) must match within epsilon.
const hold = params.outgoingVolumeHold;
const handoff = params.handoffAt;
const eps = 0.012;
const joinHold = Math.abs(volumesAt(hold - 1e-6, params).outgoing - volumesAt(hold + 1e-6, params).outgoing);
const joinHandoff = Math.abs(
  volumesAt(handoff - 1e-6, params).outgoing - volumesAt(handoff + 1e-6, params).outgoing
);

let failed = 0;
for (const [name, jump, lim] of checks) {
  const ok = jump <= lim;
  console.log(`${ok ? "OK " : "FAIL"} maxΔ ${name}=${jump.toFixed(4)} (≤${lim})`);
  if (!ok) failed++;
}
for (const [name, jump] of [
  ["hold join", joinHold],
  ["handoff join", joinHandoff],
]) {
  const ok = jump <= eps;
  console.log(`${ok ? "OK " : "FAIL"} ${name}=${jump.toFixed(5)} (≤${eps})`);
  if (!ok) failed++;
}

rmSync(envBundle.dir, { recursive: true, force: true });
rmSync(stemBundle.dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} envelope smoothness smoke(s) failed`);
  process.exit(1);
}
console.log("\nAll envelope smoothness smokes passed.");
