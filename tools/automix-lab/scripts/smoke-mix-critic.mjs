/**
 * Smoke: Mix Critic Vocal Safe / Bass Surgeon gates.
 * Run: node scripts/smoke-mix-critic.mjs
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
    const dir = mkdtempSync(join(tmpdir(), "critic-smoke-"));
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
  const dir = mkdtempSync(join(tmpdir(), "critic-smoke-"));
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

const { dir, url } = bundle(join(root, "src/audio/mixCritic.ts"));
const { critiqueMix, runMixCritic } = await import(url);

function baseParams(overrides = {}) {
  return {
    bassSwapAt: 0.5,
    handoffAt: 0.55,
    outgoingVolumeHold: 0.48,
    incomingVolumeLag: 0.12,
    bassDepth: 0.6,
    rateA: 1,
    rateB: 1,
    pitchCentsB: 0,
    targetBPM: 120,
    blendDurationSec: 16,
    cueASec: 0,
    cueBSec: 0,
    archetype: "dropSwap",
    dsp: {
      instrAPeak: 0.1,
      instrAAt: 0.4,
      instrBPeak: 0,
      instrBUntil: 0.1,
      vocalBPeak: 0.8,
      vocalBAt: 0.05,
      vocalDuckBDb: 0,
      hpfAPeak: 0.4,
      lpfBPeak: 0.1,
      echoAPeak: 0.2,
      bakeStems: false,
      bakeInstrA: false,
      bakeInstrB: false,
      bakeVocalB: false,
      decisions: [],
      mashupMode: "acapellaDrop",
      sidechainA: 0,
      ...overrides.dsp,
    },
    ...overrides,
  };
}

let failed = 0;
function check(name, cond, extra = "") {
  if (cond) console.log(`OK  ${name}${extra ? `\n      → ${extra}` : ""}`);
  else {
    console.error(`FAIL ${name}${extra ? `\n      → ${extra}` : ""}`);
    failed++;
  }
}

// Both leads hot, weak carve → must fail vocal gate.
{
  const params = baseParams();
  const report = critiqueMix({
    params,
    vocalOut: 0.85,
    vocalIn: 0.85,
    bpm: 120,
    transitionType: "eqBlend",
    harmonicOk: true,
    beatmatched: true,
  });
  check(
    "dual leads without carve → vocalClash fail",
    !report.gates.find((g) => g.id === "vocalClash").ok,
    `beats=${report.vocalClashBeats.toFixed(2)} frac=${report.vocalClashFrac.toFixed(2)}`
  );
}

// Vocal Safe should tighten and improve / pass.
{
  const params = baseParams();
  const report = runMixCritic({
    params,
    vocalOut: 0.85,
    vocalIn: 0.85,
    bpm: 120,
    transitionType: "eqBlend",
    harmonicOk: true,
    beatmatched: true,
  });
  check(
    "Vocal Safe applied on dual-lead clash",
    report.fixes.includes("Vocal Safe") && params.dsp.bakeInstrA && params.dsp.instrAPeak >= 0.9,
    `mode=${report.mode} instrAAt=${params.dsp.instrAAt} instrBUntil=${params.dsp.instrBUntil}`
  );
  check(
    "after Vocal Safe vocal gate improves or passes",
    report.vocalClashBeats <= 4.01 && report.gates.find((g) => g.id === "vocalClash").ok,
    `beats=${report.vocalClashBeats.toFixed(2)} ok=${report.gates.find((g) => g.id === "vocalClash").ok}`
  );
}

// Late bass swap + shallow depth → Bass Surgeon.
{
  const params = baseParams({ bassSwapAt: 0.55, bassDepth: 0.5 });
  // Strong carve so vocal passes; bass ownership stays shared.
  params.dsp.instrAPeak = 0.95;
  params.dsp.instrAAt = 0.08;
  params.dsp.instrBPeak = 0.9;
  params.dsp.instrBUntil = 0.45;
  params.dsp.vocalBAt = 0.45;
  params.dsp.bakeInstrA = true;
  params.dsp.bakeInstrB = true;
  const before = critiqueMix({
    params,
    vocalOut: 0.2,
    vocalIn: 0.2,
    bpm: 120,
    transitionType: "eqBlend",
    harmonicOk: true,
    beatmatched: true,
  });
  const report = runMixCritic({
    params,
    vocalOut: 0.2,
    vocalIn: 0.2,
    bpm: 120,
    transitionType: "eqBlend",
    harmonicOk: true,
    beatmatched: true,
  });
  check(
    "shared bass mid-window → Bass Surgeon or already ok",
    before.gates.find((g) => g.id === "bassClash").ok || report.fixes.includes("Bass Surgeon"),
    `beforeFrac=${before.bassClashFrac.toFixed(2)} fixes=${report.fixes.join(",")}`
  );
}

// Clean acapellaDrop-like recipe should pass.
{
  const params = baseParams({
    bassSwapAt: 0.2,
    bassDepth: 1.1,
    dsp: {
      instrAPeak: 0.55,
      instrAAt: 0.08,
      instrBPeak: 0,
      instrBUntil: 0.04,
      vocalBPeak: 0,
      vocalBAt: 0.06,
      vocalDuckBDb: 0,
      hpfAPeak: 0.55,
      lpfBPeak: 0.12,
      echoAPeak: 0.35,
      bakeStems: true,
      bakeInstrA: true,
      bakeInstrB: false,
      bakeVocalB: false,
      decisions: [],
      mashupMode: "acapellaDrop",
      sidechainA: 0,
    },
  });
  const report = critiqueMix({
    params,
    vocalOut: 0.25,
    vocalIn: 0.7,
    bpm: 120,
    transitionType: "eqBlend",
    harmonicOk: true,
    beatmatched: true,
  });
  check(
    "acapellaDrop-like recipe → critic pass",
    report.ok && report.mode === "pass",
    `score=${report.score} vocalBeats=${report.vocalClashBeats.toFixed(2)} gates=${report.gates.map((g) => g.id + (g.ok ? "" : "!")).join(",")}`
  );
}

// Late handoff leaves no room to settle rate/pitch/level.
{
  const params = baseParams({
    handoffAt: 0.9,
    bassSwapAt: 0.24,
    bassDepth: 1.1,
    dsp: {
      instrAPeak: 0.95,
      instrAAt: 0.08,
      instrBPeak: 0,
      instrBUntil: 0.06,
      vocalBPeak: 0,
      vocalBAt: 0.1,
      vocalDuckBDb: 0,
      hpfAPeak: 0.7,
      lpfBPeak: 0.1,
      echoAPeak: 0.2,
      bakeStems: true,
      bakeInstrA: true,
      bakeInstrB: false,
      bakeVocalB: false,
      decisions: [],
      mashupMode: "acapellaDrop",
      sidechainA: 0,
    },
  });
  const report = critiqueMix({
    params,
    vocalOut: 0.2,
    vocalIn: 0.7,
    bpm: 120,
    transitionType: "eqBlend",
    harmonicOk: true,
    beatmatched: true,
  });
  const land = report.gates.find((g) => g.id === "land");
  check(
    "late handoff → LAND fail",
    land && !land.ok && !report.ok,
    land ? land.detail : "no land gate"
  );
}

// High instr envelope without a baked leadKill is still a dual lead.
{
  const params = baseParams({
    bassSwapAt: 0.2,
    bassDepth: 1.15,
    handoffAt: 0.55,
    dsp: {
      instrAPeak: 0.95,
      instrAAt: 0.08,
      instrBPeak: 0,
      instrBUntil: 0.05,
      vocalBPeak: 0.8,
      vocalBAt: 0.1,
      vocalDuckBDb: 0,
      hpfAPeak: 0.55,
      lpfBPeak: 0.1,
      echoAPeak: 0.2,
      bakeStems: false,
      bakeInstrA: false,
      bakeInstrB: false,
      bakeVocalB: false,
      decisions: [],
      mashupMode: "textureBed",
      sidechainA: 0,
    },
  });
  const before = critiqueMix({
    params,
    vocalOut: 0.82,
    vocalIn: 0.82,
    bpm: 120,
    transitionType: "eqBlend",
    harmonicOk: true,
    beatmatched: true,
  });
  check(
    "soft high instr without bake → vocalClash fail",
    !before.gates.find((g) => g.id === "vocalClash").ok,
    `beats=${before.vocalClashBeats.toFixed(2)}`
  );
  const report = runMixCritic({
    params,
    vocalOut: 0.82,
    vocalIn: 0.82,
    bpm: 120,
    transitionType: "eqBlend",
    harmonicOk: true,
    beatmatched: true,
  });
  check(
    "Vocal Safe bakes the bed",
    report.fixes.includes("Vocal Safe") && params.dsp.bakeInstrA && params.dsp.bakeStems,
    `mode=${report.mode} peak=${params.dsp.instrAPeak}`
  );
  check(
    "vocal gate passes once the carve is real",
    report.gates.find((g) => g.id === "vocalClash").ok,
    `beats=${report.vocalClashBeats.toFixed(2)}`
  );
}

rmSync(dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} Mix Critic smoke(s) failed.`);
  process.exit(1);
}
console.log("\nAll Mix Critic smokes passed.");
