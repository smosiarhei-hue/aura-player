/**
 * Full-stack Adaptive Duet plan + coach smoke (no audio).
 * Run: node scripts/smoke-one-bar-duet.mjs
 */
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const require = createRequire(import.meta.url);

function bundle(entry, outfileName = "out.mjs") {
  let esbuild;
  try {
    esbuild = require("esbuild");
  } catch {
    const dir = mkdtempSync(join(tmpdir(), "duet-smoke-"));
    const out = join(dir, outfileName);
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
  const dir = mkdtempSync(join(tmpdir(), "duet-smoke-"));
  const out = join(dir, outfileName);
  esbuild.buildSync({
    entryPoints: [entry],
    bundle: true,
    platform: "node",
    format: "esm",
    outfile: out,
  });
  return { dir, url: pathToFileURL(out).href };
}

const planBundle = bundle(join(root, "src/audio/oneBarDuet.ts"), "duet.mjs");
const { planOneBarDuet, pickDuetWindow, ONE_BAR_DUET_MODE } = await import(planBundle.url);

const coachEntry = join(planBundle.dir, "coach-entry.ts");
writeFileSync(
  coachEntry,
  `export { scoreTransition, simulateTrail } from ${JSON.stringify(join(root, "src/audio/transitionCoach.ts"))};`
);
const coachBundle = bundle(coachEntry, "coach.mjs");
const { scoreTransition, simulateTrail } = await import(coachBundle.url);

function vocalCurve(n, pattern) {
  const out = Array.from({ length: n }, () => 0.12);
  for (const p of pattern) {
    for (let i = p.from; i < p.to && i < n; i++) out[i] = p.level;
  }
  return out;
}

function fakeProfile(overrides = {}) {
  const durationSec = overrides.durationSec ?? 200;
  const hops = Math.floor(durationSec / 0.25);
  const mixOut = overrides.mixOutSec ?? 176;
  const mixOutHop = Math.floor(mixOut / 0.25);
  const vocalPresence =
    overrides.vocalPresence ??
    vocalCurve(hops, [
      { from: 0, to: mixOutHop, level: 0.55 },
      { from: mixOutHop, to: mixOutHop + 28, level: 0.72 },
      { from: mixOutHop + 28, to: mixOutHop + 40, level: 0.18 },
      { from: mixOutHop + 40, to: hops, level: 0.25 },
    ]);
  const energy = overrides.energy ?? Array.from({ length: hops }, () => 0.62);
  return {
    name: "t",
    bpm: 120,
    bpmConfidence: 0.9,
    camelotKey: "8A",
    keyConfidence: 0.8,
    durationSec,
    mixOutSec: mixOut,
    mixInSec: 8,
    hasFadeOut: false,
    endsInSilence: false,
    tempoStability: 0.9,
    energy,
    vocalPresence,
    reason: "smoke LRC phrase end",
    ...overrides,
    energy: overrides.energy ?? energy,
    vocalPresence: overrides.vocalPresence ?? vocalPresence,
  };
}

const a = fakeProfile();
const b = fakeProfile({
  mixInSec: 4,
  mixOutSec: 170,
  camelotKey: "9A", // adjacent — natural compatible
  reason: "smoke Whisper intro",
  bpm: 124, // needs stretch
  vocalPresence: vocalCurve(800, [
    { from: 0, to: 12, level: 0.15 },
    { from: 16, to: 60, level: 0.75 },
    { from: 60, to: 72, level: 0.2 },
    { from: 72, to: 800, level: 0.5 },
  ]),
});

const pick = pickDuetWindow(a, b, 120);
assert.ok(pick.bars >= 2 && pick.bars <= 12);
assert.equal(pick.beats, pick.bars * 4);
assert.ok(pick.handoffAt <= 0.7 + 1e-6);

const plan = planOneBarDuet(a, b);
assert.equal(plan.params.dsp.mashupMode, ONE_BAR_DUET_MODE);
assert.equal(plan.params.dsp.bakeStems, false);
assert.equal(plan.params.dsp.bakeInstrA, false);
assert.ok(plan.params.handoffAt <= 0.7 + 1e-6);
assert.ok(plan.params.dsp.hpfAPeak >= 0.7);
assert.ok(plan.params.dsp.lpfBPeak >= 0.2);
assert.ok(plan.params.dsp.echoAPeak > 0 && plan.params.dsp.echoAPeak <= 0.28);
assert.ok(plan.params.dsp.sidechainA > 0.2);
// Soft carve when both hot — not nuclear
assert.ok(plan.params.dsp.instrAPeak >= 0 && plan.params.dsp.instrAPeak < 0.85);
assert.ok(Math.abs(plan.params.rateB - 1) >= 0.004 || Math.abs(plan.params.rateA - 1) >= 0.004, "expect tempo stretch");
assert.ok(plan.params.dsp.decisions.some((d) => /bars|beats|Time-stretch|Camelot|ONE BASS|Soft A|FX/i.test(d)));
assert.match(plan.story, /bars|beats|LAND/i);

const trail = simulateTrail(plan.params, 120);
const report = scoreTransition(trail, {
  mode: plan.params.dsp.mashupMode,
  handoffAt: plan.params.handoffAt,
  vocalBAt: plan.params.dsp.vocalBAt,
  instrAAt: plan.params.dsp.instrAAt,
  bassSwapAt: plan.params.bassSwapAt,
  nuclearCarve: false,
});
assert.ok(report.ok, `coach ${report.story} ${JSON.stringify(report.gates)}`);
assert.ok(report.score >= 80);

console.log(
  "Full-stack Duet smoke OK ·",
  `${plan.params.blendDurationSec.toFixed(2)}s · ${pick.bars} bars/${pick.beats} beats`,
  `· carve ${plan.params.dsp.instrAPeak}`,
  `· rateB ${plan.params.rateB.toFixed(3)}`,
  `· coach ${report.score}/100`,
  `· ${pick.reason}`
);

rmSync(planBundle.dir, { recursive: true, force: true });
rmSync(coachBundle.dir, { recursive: true, force: true });
