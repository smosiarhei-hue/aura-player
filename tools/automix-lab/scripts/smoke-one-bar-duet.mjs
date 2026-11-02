/**
 * Adaptive B-led Phrase Duet plan + coach smoke (no audio).
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

// Coach + simulate from transitionCoach (pulls envelopes)
const coachEntry = join(planBundle.dir, "coach-entry.ts");
writeFileSync(
  coachEntry,
  `
export { scoreTransition, simulateTrail } from ${JSON.stringify(join(root, "src/audio/transitionCoach.ts"))};
`
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
  const energy = overrides.energy ?? Array.from({ length: hops }, () => 0.6);
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
  reason: "smoke Whisper intro",
  vocalPresence: vocalCurve(800, [
    { from: 0, to: 12, level: 0.15 },
    { from: 16, to: 60, level: 0.75 },
    { from: 60, to: 72, level: 0.2 },
    { from: 72, to: 800, level: 0.5 },
  ]),
});

const pick = pickDuetWindow(a, b, 120);
assert.ok(pick.blendSec >= 4 && pick.blendSec <= 28, `blend ${pick.blendSec}`);
assert.ok(pick.bars >= 2 && pick.bars <= 12, `bars ${pick.bars}`);
assert.ok(pick.handoffAt <= 0.7 + 1e-6, `handoff ${pick.handoffAt}`);
assert.ok(pick.aDuck < 0.85, `aDuck ${pick.aDuck}`);

const plan = planOneBarDuet(a, b);
assert.equal(plan.params.dsp.mashupMode, ONE_BAR_DUET_MODE);
assert.ok(plan.params.handoffAt <= 0.7 + 1e-6);
assert.equal(plan.params.dsp.bakeStems, false);
assert.match(plan.story, /B-led|bars/i);

const trail = simulateTrail(plan.params, 100);
const report = scoreTransition(trail, {
  mode: plan.params.dsp.mashupMode,
  handoffAt: plan.params.handoffAt,
  vocalBAt: plan.params.dsp.vocalBAt,
  instrAAt: plan.params.dsp.instrAAt,
  bassSwapAt: plan.params.bassSwapAt,
  nuclearCarve: false,
});
assert.equal(report.mode, "oneBarDuet");
assert.ok(report.ok, `coach should pass duet: ${report.story} ${JSON.stringify(report.gates)}`);
assert.ok(report.score >= 80, `score ${report.score}`);

// Mid dual: B >= A most of the time
const mid = trail.filter((s) => s.p > 0.15 && s.p < plan.params.handoffAt - 0.02);
const bLed = mid.filter((s) => s.volB + 0.02 >= s.volA).length;
assert.ok(bLed >= mid.length * 0.5, `B-led ratio ${bLed}/${mid.length}`);

console.log(
  "Adaptive B-led Duet smoke OK ·",
  `${plan.params.blendDurationSec.toFixed(2)}s · ${pick.bars} bars · handoff ${plan.params.handoffAt} · coach ${report.score}/100 · ${pick.reason}`
);

rmSync(planBundle.dir, { recursive: true, force: true });
rmSync(coachBundle.dir, { recursive: true, force: true });
