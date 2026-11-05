/**
 * Smoke: Space Reverb / Loop / Echo DSP recipe fields from aiMixEngine.
 * Run: node scripts/smoke-fx-palette.mjs
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const require = createRequire(import.meta.url);

function bundle(entry) {
  const esbuild = require("esbuild");
  const dir = mkdtempSync(join(tmpdir(), "fx-smoke-"));
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

function profile(partial) {
  return {
    name: partial.name ?? "t",
    durationSec: partial.durationSec ?? 210,
    bpm: partial.bpm ?? 122,
    bpmConfidence: 0.9,
    camelotKey: partial.camelotKey ?? "8A",
    keyConfidence: 0.9,
    energy: partial.energy ?? Array.from({ length: 48 }, () => 0.5),
    vocalPresence: partial.vocalPresence ?? Array.from({ length: 48 }, () => 0.35),
    mixInSec: partial.mixInSec ?? 8,
    mixOutSec: partial.mixOutSec ?? 186,
    hasFadeOut: false,
    endsInSilence: false,
    tempoStability: partial.tempoStability ?? 0.85,
    downbeatsSec: Array.from({ length: 80 }, (_, i) => i * 2),
    beatsSec: Array.from({ length: 320 }, (_, i) => i * 0.5),
    reason: "smoke",
  };
}

const { dir, url } = bundle(join(root, "src/audio/aiMixEngine.ts"));
const { planAutomix } = await import(url);

let failed = 0;

const space = planAutomix(
  profile({
    name: "A-space",
    bpm: 122,
    camelotKey: "8A",
    mixOutSec: 186,
    durationSec: 210,
    energy: Array.from({ length: 48 }, () => 0.5),
    tempoStability: 0.55,
  }),
  profile({
    name: "B-space",
    bpm: 124,
    camelotKey: "8A",
    energy: Array.from({ length: 48 }, () => 0.52),
    tempoStability: 0.55,
  })
);
const okSpace =
  space.params.archetype === "spaceReverb" &&
  space.params.dsp.reverbAPeak >= 0.5 &&
  space.params.dsp.echoAPeak > 0.2 &&
  space.params.dsp.loopBarsA >= 2;
console.log(
  `${okSpace ? "OK" : "FAIL"}  spaceReverb recipe · arch=${space.params.archetype} rev=${space.params.dsp.reverbAPeak} echo=${space.params.dsp.echoAPeak} loop=${space.params.dsp.loopBarsA}`
);
if (!okSpace) failed++;

const long = planAutomix(
  profile({
    name: "A-long",
    bpm: 124,
    camelotKey: "8A",
    mixOutSec: 120,
    durationSec: 240,
    energy: Array.from({ length: 48 }, () => 0.55),
    tempoStability: 0.9,
  }),
  profile({
    name: "B-long",
    bpm: 126,
    camelotKey: "8A",
    energy: Array.from({ length: 48 }, () => 0.58),
    tempoStability: 0.9,
  })
);
const okLong =
  long.params.archetype === "seamlessLoop" &&
  long.params.dsp.loopBarsA >= 2 &&
  long.params.dsp.echoAPeak >= 0.2;
console.log(
  `${okLong ? "OK" : "FAIL"}  seamlessLoop recipe · arch=${long.params.archetype} loop=${long.params.dsp.loopBarsA} echo=${long.params.dsp.echoAPeak}`
);
if (!okLong) failed++;

const stutter = planAutomix(
  profile({
    name: "A-stut",
    bpm: 122,
    camelotKey: "8A",
    mixOutSec: 160,
    durationSec: 210,
    energy: Array.from({ length: 48 }, (_, i) => (i < 34 ? 0.45 : 0.4)),
    tempoStability: 0.85,
  }),
  profile({
    name: "B-stut",
    bpm: 124,
    camelotKey: "8A",
    energy: Array.from({ length: 48 }, (_, i) => (i < 12 ? 0.78 : 0.6)),
    tempoStability: 0.85,
  })
);
const okStut =
  stutter.params.archetype === "beatStutter" && stutter.params.dsp.stutterAPeak >= 0.7;
console.log(
  `${okStut ? "OK" : "FAIL"}  beatStutter recipe · arch=${stutter.params.archetype} stutter=${stutter.params.dsp.stutterAPeak}`
);
if (!okStut) failed++;

rmSync(dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nAll FX palette smokes passed.");
