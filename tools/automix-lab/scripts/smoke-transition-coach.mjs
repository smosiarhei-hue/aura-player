/**
 * Smoke: transition coach scoring + learn nudges.
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
    const dir = mkdtempSync(join(tmpdir(), "csmoke-"));
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
  const dir = mkdtempSync(join(tmpdir(), "csmoke-"));
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

const b = bundle(join(root, "src/audio/transitionCoach.ts"));
const {
  scoreTransition,
  simulateTrail,
  applyCoachOffsets,
  learnFromReport,
  DEFAULT_OFFSETS,
} = await import(b.url);
const env = bundle(join(root, "src/audio/envelopes.ts"));
const { defaultParams, bakedLeadKill } = await import(env.url);

let failed = 0;
function check(name, cond, extra = "") {
  if (cond) console.log(`OK  ${name}${extra ? `\n      → ${extra}` : ""}`);
  else {
    console.error(`FAIL ${name}${extra ? `\n      → ${extra}` : ""}`);
    failed++;
  }
}

const good = defaultParams();
good.dsp.mashupMode = "acapellaDrop";
good.dsp.instrAPeak = 0.95;
good.dsp.instrAAt = 0.08;
good.dsp.instrBPeak = 0.9;
good.dsp.instrBUntil = 0.4;
good.dsp.vocalBAt = 0.4;
good.dsp.hpfAPeak = 0.7;
good.dsp.echoAPeak = 0.25;
good.bassSwapAt = 0.2;
good.handoffAt = 0.55;
good.outgoingVolumeHold = 0.22;
good.bassDepth = 1.1;
good.rateA = 0.99;
good.rateB = 1.02;
good.pitchCentsB = 50;
good.targetBPM = 120;

const trailGood = simulateTrail(good, 80);
const reportGood = scoreTransition(trailGood, {
  mode: "acapellaDrop",
  handoffAt: good.handoffAt,
  vocalBAt: good.dsp.vocalBAt,
  instrAAt: good.dsp.instrAAt,
  bassSwapAt: good.bassSwapAt,
  nuclearCarve: bakedLeadKill(good.dsp),
});
check("good recipe scores high", reportGood.score >= 70, reportGood.story);

const bad = defaultParams();
bad.dsp.mashupMode = "acapellaDrop";
bad.dsp.instrAPeak = 0.2;
bad.dsp.instrAAt = 0.4;
bad.dsp.instrBPeak = 0;
bad.dsp.vocalBAt = 0.1;
bad.bassSwapAt = 0.5;
bad.handoffAt = 0.55;
bad.outgoingVolumeHold = 0.7;
bad.dsp.hpfAPeak = 0.1;
bad.dsp.echoAPeak = 0.9;
const trailBad = simulateTrail(bad, 80);
const reportBad = scoreTransition(trailBad, {
  mode: "acapellaDrop",
  handoffAt: bad.handoffAt,
  vocalBAt: bad.dsp.vocalBAt,
  instrAAt: bad.dsp.instrAAt,
  bassSwapAt: bad.bassSwapAt,
});
check("bad recipe fails", !reportBad.ok && reportBad.score < reportGood.score, reportBad.story);
check("bad recipe suggests nudges", reportBad.tweaks.length > 0, reportBad.tweaks.join(", "));

let coach = { ...DEFAULT_OFFSETS };
const learned = learnFromReport(coach, reportBad);
check(
  "learn increases offsets",
  learned.earlierCarve > 0 || learned.laterVocalOpen > 0 || learned.quieterDualA > 0,
  JSON.stringify({
    carve: learned.earlierCarve,
    cue: learned.cueShiftSec,
    vocal: learned.laterVocalOpen,
    quiet: learned.quieterDualA,
  })
);

const tuned = defaultParams();
Object.assign(tuned, bad);
tuned.dsp = { ...bad.dsp, decisions: [] };
applyCoachOffsets(tuned, learned);
check(
  "apply offsets moves carve earlier / vocal later",
  tuned.dsp.instrAAt <= bad.dsp.instrAAt && tuned.dsp.vocalBAt >= bad.dsp.vocalBAt,
  `instrAAt ${bad.dsp.instrAAt}→${tuned.dsp.instrAAt} vocalBAt ${bad.dsp.vocalBAt}→${tuned.dsp.vocalBAt}`
);

// Partial carve used to clear noDualLead (instrA 0.7 threshold) while A still sings under dry B.
const sneaky = defaultParams();
sneaky.dsp.mashupMode = "acapellaDrop";
sneaky.dsp.instrAPeak = 0.82;
sneaky.dsp.instrAAt = 0.08;
sneaky.dsp.instrBPeak = 0.9;
sneaky.dsp.instrBUntil = 0.35;
sneaky.dsp.vocalBAt = 0.4;
sneaky.dsp.hpfAPeak = 0.7;
sneaky.dsp.echoAPeak = 0.25;
sneaky.bassSwapAt = 0.2;
sneaky.handoffAt = 0.55;
sneaky.outgoingVolumeHold = 0.22;
sneaky.bassDepth = 1.1;
sneaky.rateB = 1.01;
sneaky.pitchCentsB = 20;
const reportSneaky = scoreTransition(simulateTrail(sneaky, 80), {
  mode: "acapellaDrop",
  handoffAt: sneaky.handoffAt,
  vocalBAt: sneaky.dsp.vocalBAt,
  instrAAt: sneaky.dsp.instrAAt,
  bassSwapAt: sneaky.bassSwapAt,
});
const dualGate = reportSneaky.gates.find((g) => g.id === "noDualLead");
check(
  "partial carve dual-vocal fails",
  !reportSneaky.ok && dualGate && !dualGate.ok,
  reportSneaky.story + " · " + (dualGate?.detail || "missing gate")
);

// Envelope says A is a bed (instrA 0.95) but nothing was baked — still two leads.
const fakeBed = defaultParams();
fakeBed.dsp.mashupMode = "acapellaDrop";
fakeBed.dsp.instrAPeak = 0.95;
fakeBed.dsp.instrAAt = 0.08;
fakeBed.dsp.instrBPeak = 0.9;
fakeBed.dsp.instrBUntil = 0.35;
fakeBed.dsp.vocalBAt = 0.4;
fakeBed.dsp.bakeInstrA = false;
fakeBed.dsp.bakeStems = false;
fakeBed.dsp.hpfAPeak = 0.7;
fakeBed.dsp.echoAPeak = 0.25;
fakeBed.bassSwapAt = 0.2;
fakeBed.handoffAt = 0.55;
fakeBed.outgoingVolumeHold = 0.22;
fakeBed.bassDepth = 1.1;
fakeBed.rateB = 1.01;
fakeBed.pitchCentsB = 20;
const reportFake = scoreTransition(simulateTrail(fakeBed, 80), {
  mode: "acapellaDrop",
  handoffAt: fakeBed.handoffAt,
  vocalBAt: fakeBed.dsp.vocalBAt,
  instrAAt: fakeBed.dsp.instrAAt,
  bassSwapAt: fakeBed.bassSwapAt,
  nuclearCarve: bakedLeadKill(fakeBed.dsp),
});
const fakeDual = reportFake.gates.find((g) => g.id === "noDualLead");
check(
  "unbaked envelope bed fails dual-vocal",
  !reportFake.ok && fakeDual && !fakeDual.ok && bakedLeadKill(fakeBed.dsp) === false,
  reportFake.story + " · " + (fakeDual?.detail || "missing gate")
);
check(
  "cue shift does not shorten the phrase",
  tuned.blendDurationSec === bad.blendDurationSec,
  `blend ${bad.blendDurationSec}→${tuned.blendDurationSec}`
);

const late = defaultParams();
late.dsp.mashupMode = "acapellaDrop";
late.dsp.instrAPeak = 0.95;
late.dsp.instrAAt = 0.08;
late.dsp.vocalBAt = 0.16;
late.dsp.hpfAPeak = 0.8;
late.dsp.echoAPeak = 0.2;
late.bassSwapAt = 0.22;
late.handoffAt = 0.9;
late.outgoingVolumeHold = 0.3;
late.pitchCentsB = 100;
late.rateB = 1.06;
late.blendDurationSec = 28;
const trailLate = simulateTrail(late, 80);
const reportLate = scoreTransition(trailLate, {
  mode: "acapellaDrop",
  handoffAt: late.handoffAt,
  vocalBAt: late.dsp.vocalBAt,
  instrAAt: late.dsp.instrAAt,
  bassSwapAt: late.bassSwapAt,
  nuclearCarve: bakedLeadKill(late.dsp),
});
const lateGate = reportLate.gates.find((g) => g.id === "landTiming");
check(
  "late LAND fails",
  !reportLate.ok && lateGate && !lateGate.ok,
  reportLate.story + (lateGate ? ` · ${lateGate.detail}` : "")
);
const learnedLate = learnFromReport({ ...DEFAULT_OFFSETS }, reportLate);
check(
  "late LAND nudges cue earlier",
  learnedLate.cueShiftSec < 0,
  `cueShiftSec=${learnedLate.cueShiftSec}`
);

rmSync(b.dir, { recursive: true, force: true });
rmSync(env.dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} coach smoke(s) failed`);
  process.exit(1);
}
console.log("\nAll transition coach smokes passed.");
