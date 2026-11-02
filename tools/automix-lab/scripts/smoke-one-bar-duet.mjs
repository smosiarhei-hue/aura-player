/**
 * Headless Adaptive Phrase Duet plan smoke (no audio).
 * Run: node scripts/smoke-one-bar-duet.mjs
 */
import assert from "node:assert/strict";
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
    const dir = mkdtempSync(join(tmpdir(), "duet-smoke-"));
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
  const dir = mkdtempSync(join(tmpdir(), "duet-smoke-"));
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

const { dir, url } = bundle(join(root, "src/audio/oneBarDuet.ts"));
const { planOneBarDuet, pickDuetWindow, ONE_BAR_DUET_MODE } = await import(url);

function vocalCurve(n, pattern) {
  // pattern: array of {from,to,level} in hop units
  const out = Array.from({ length: n }, () => 0.12);
  for (const p of pattern) {
    for (let i = p.from; i < p.to && i < n; i++) out[i] = p.level;
  }
  return out;
}

function fakeProfile(overrides = {}) {
  const durationSec = overrides.durationSec ?? 200;
  const hops = Math.floor(durationSec / 0.25);
  // Strong dual vocals for ~10s after mixOut, then A breath — should prefer ~8–12s.
  const mixOut = overrides.mixOutSec ?? 176;
  const mixOutHop = Math.floor(mixOut / 0.25);
  const vocalPresence =
    overrides.vocalPresence ??
    vocalCurve(hops, [
      { from: 0, to: mixOutHop, level: 0.55 },
      { from: mixOutHop, to: mixOutHop + 36, level: 0.72 }, // ~9s dual
      { from: mixOutHop + 36, to: mixOutHop + 48, level: 0.18 }, // breath
      { from: mixOutHop + 48, to: hops, level: 0.25 },
    ]);
  const energy = overrides.energy ?? Array.from({ length: hops }, () => 0.6);
  return {
    name: "t",
    title: "t",
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
    // keep curves if overrides replaced duration without curves
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
    { from: 16, to: 60, level: 0.75 }, // strong B vocal from cue
    { from: 60, to: 72, level: 0.2 },
    { from: 72, to: 800, level: 0.5 },
  ]),
});

const pick = pickDuetWindow(a, b, 120);
assert.ok(pick.blendSec >= 4 && pick.blendSec <= 36, `blend ${pick.blendSec}`);
assert.ok(pick.bars >= 2 && pick.bars <= 16, `bars ${pick.bars}`);
assert.ok(pick.score > 0.5, `score ${pick.score}`);

const plan = planOneBarDuet(a, b);
assert.equal(plan.params.dsp.mashupMode, ONE_BAR_DUET_MODE);
assert.ok(plan.params.blendDurationSec >= 4 && plan.params.blendDurationSec <= 36);
assert.equal(plan.params.dsp.instrAPeak, 0);
assert.equal(plan.params.dsp.instrBPeak, 0);
assert.equal(plan.params.dsp.bakeStems, false);
assert.equal(plan.critic.ok, true);
assert.match(plan.story, /DUET/);
assert.match(plan.story, /listened|bars/i);
assert.ok(plan.params.cueASec < plan.profileA.durationSec - 1);
assert.ok(
  plan.profileA.durationSec - plan.params.cueASec >= plan.params.blendDurationSec - 0.15
);
assert.ok(
  plan.params.dsp.decisions.some((d) => /vocal|bars|listened|Adaptive/i.test(d)),
  "decisions should explain listen"
);

// Short vocal collide → shorter pick than long dual bed.
const shortA = fakeProfile({
  vocalPresence: vocalCurve(800, [
    { from: 0, to: 700, level: 0.5 },
    { from: 704, to: 716, level: 0.7 }, // ~3s
    { from: 716, to: 724, level: 0.15 },
    { from: 724, to: 800, level: 0.2 },
  ]),
  mixOutSec: 176,
});
const shortPick = pickDuetWindow(shortA, b, 120);
assert.ok(
  shortPick.blendSec <= pick.blendSec + 0.01,
  `short ${shortPick.blendSec} should not exceed rich ${pick.blendSec}`
);

console.log(
  "Adaptive Phrase Duet smoke OK ·",
  `${plan.params.blendDurationSec.toFixed(2)}s · ${pick.bars} bars · cueA ${plan.params.cueASec.toFixed(1)}s · ${pick.reason}`
);

rmSync(dir, { recursive: true, force: true });
