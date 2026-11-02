/**
 * Headless One-Bar Duet plan smoke (no audio).
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
const { planOneBarDuet, ONE_BAR_DUET_MODE } = await import(url);

function fakeProfile(overrides = {}) {
  return {
    title: "t",
    bpm: 120,
    durationSec: 200,
    mixOutSec: 176,
    mixInSec: 8,
    keyCamelot: "8A",
    energy: Array.from({ length: 800 }, () => 0.6),
    vocalPresence: Array.from({ length: 800 }, () => 0.7),
    endsInSilence: false,
    reason: "smoke",
    ...overrides,
  };
}

const plan = planOneBarDuet(fakeProfile(), fakeProfile({ mixInSec: 4 }));
assert.equal(plan.params.dsp.mashupMode, ONE_BAR_DUET_MODE);
assert.ok(plan.params.blendDurationSec >= 1.5 && plan.params.blendDurationSec <= 4.2);
assert.equal(plan.params.dsp.instrAPeak, 0);
assert.equal(plan.params.dsp.instrBPeak, 0);
assert.equal(plan.params.dsp.bakeStems, false);
assert.equal(plan.critic.ok, true);
assert.match(plan.story, /DUET/);
assert.ok(plan.params.cueASec < plan.profileA.durationSec - 1);

console.log(
  "One-Bar Duet smoke OK ·",
  `${plan.params.blendDurationSec.toFixed(2)}s · cueA ${plan.params.cueASec.toFixed(1)}s`
);

rmSync(dir, { recursive: true, force: true });
