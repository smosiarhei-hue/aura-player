/**
 * Smoke test: Camelot + TZ §2.4 planner (no browser).
 * Run: node scripts/smoke-tz-planner.mjs
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;

// Compile the two TS modules via esbuild-free path: use tsc project emit to temp,
// or transpile with node --experimental if available. Prefer vite/esbuild from node_modules.
const esbuildBin = join(root, "node_modules/esbuild/bin/esbuild");
const require = createRequire(import.meta.url);

function bundle(entry) {
  let esbuild;
  try {
    esbuild = require("esbuild");
  } catch {
    // Fall back: spawn npx esbuild
    const dir = mkdtempSync(join(tmpdir(), "tz-smoke-"));
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
  const dir = mkdtempSync(join(tmpdir(), "tz-smoke-"));
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
    durationSec: partial.durationSec ?? 180,
    bpm: partial.bpm ?? 120,
    bpmConfidence: 0.8,
    camelotKey: partial.camelotKey ?? null,
    keyConfidence: 0.7,
    energy: partial.energy ?? Array.from({ length: 40 }, (_, i) => (i < 28 ? 0.6 : 0.35)),
    vocalPresence: partial.vocalPresence ?? Array.from({ length: 40 }, () => 0.5),
    mixInSec: partial.mixInSec ?? 8,
    mixOutSec: partial.mixOutSec ?? 148,
    hasFadeOut: false,
    endsInSilence: false,
    tempoStability: partial.tempoStability ?? 0.8,
    reason: "smoke",
  };
}

const { dir, url } = bundle(join(root, "src/audio/transitionPlanner.ts"));
const { planTransitionType, transitionTypeLabel } = await import(url);

const cases = [
  {
    name: "far BPM + incompatible key → echo/cut",
    a: profile({ bpm: 100, camelotKey: "1A", mixOutSec: 140, durationSec: 180 }),
    b: profile({ bpm: 128, camelotKey: "8B" }),
    outro: 40,
    expect: (t) => t === "echoOut" || t === "cutOnOne",
  },
  {
    name: "compatible + close BPM + stable → long/eq blend",
    a: profile({
      bpm: 120,
      camelotKey: "8A",
      tempoStability: 0.85,
      mixOutSec: 140,
      durationSec: 200,
      energy: Array.from({ length: 48 }, () => 0.55),
    }),
    b: profile({
      bpm: 122,
      camelotKey: "9A",
      tempoStability: 0.85,
      energy: Array.from({ length: 48 }, () => 0.55),
    }),
    outro: 60,
    expect: (t) => t === "eqBlend" || t === "longBlend",
  },
  {
    name: "energy up → filter sweep",
    a: profile({
      bpm: 120,
      camelotKey: "8A",
      energy: Array.from({ length: 40 }, (_, i) => (i < 28 ? 0.7 : 0.25)),
    }),
    b: profile({
      bpm: 121,
      camelotKey: "8A",
      energy: Array.from({ length: 40 }, (_, i) => (i < 10 ? 0.85 : 0.6)),
    }),
    outro: 40,
    expect: (t) => t === "filterSweep",
  },
  {
    name: "short outro → echo out",
    a: profile({ bpm: 120, camelotKey: "8A", mixOutSec: 170, durationSec: 180 }),
    b: profile({ bpm: 120, camelotKey: "8A" }),
    outro: 10,
    expect: (t) => t === "echoOut",
  },
  {
    name: "same key adjacent BPM → eq blend path",
    a: profile({
      bpm: 124,
      camelotKey: "5A",
      tempoStability: 0.5,
      energy: Array.from({ length: 40 }, () => 0.5),
    }),
    b: profile({
      bpm: 126,
      camelotKey: "5A",
      tempoStability: 0.5,
      energy: Array.from({ length: 40 }, () => 0.5),
    }),
    outro: 32,
    expect: (t) => t === "eqBlend" || t === "longBlend" || t === "smartCrossfade",
  },
  {
    name: "close BPM + key clash → Echo Out (not short Smart Crossfade)",
    a: profile({
      bpm: 117,
      camelotKey: "8B",
      energy: Array.from({ length: 40 }, () => 0.5),
    }),
    b: profile({
      bpm: 124,
      camelotKey: "4B",
      energy: Array.from({ length: 40 }, () => 0.5),
    }),
    outro: 38,
    expect: (t) => t === "echoOut",
  },
];

let failed = 0;
for (const c of cases) {
  const d = planTransitionType(c.a, c.b, c.outro);
  const ok = c.expect(d.type);
  console.log(
    `${ok ? "OK" : "FAIL"}  ${c.name}\n      → ${transitionTypeLabel(d.type)} (${d.type}) · ${d.reason}`
  );
  if (!ok) failed++;
}

// Camelot unit checks via same bundle (re-export through planner's import)
const keyMod = bundle(join(root, "src/audio/keyCamelot.ts"));
const { camelotCompatible, camelotMatch, estimateCamelotKey } = await import(keyMod.url);

const chromaCMajor = [0.25, 0.05, 0.08, 0.04, 0.18, 0.12, 0.05, 0.15, 0.04, 0.1, 0.04, 0.06];
const key = estimateCamelotKey(chromaCMajor);
console.log(`OK  chroma→key sample: ${key.camelot} conf=${key.confidence.toFixed(2)}`);

if (!camelotCompatible("8A", "9A")) {
  console.log("FAIL  8A↔9A should be adjacent compatible");
  failed++;
} else console.log("OK  8A↔9A adjacent");

const clash = camelotMatch("1A", "8B");
if (clash.isNaturallyCompatible) {
  console.log("FAIL  1A↔8B should not be naturally compatible");
  failed++;
} else console.log(`OK  1A↔8B clash: ${clash.description}`);

rmSync(dir, { recursive: true, force: true });
rmSync(keyMod.dir, { recursive: true, force: true });

if (failed) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nAll TZ planner smokes passed.");
void esbuildBin;
