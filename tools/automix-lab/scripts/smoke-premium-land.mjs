/**
 * Smoke: Premium LAND automation (bar-snap handoff, settle, feature catalog).
 * Run: node scripts/smoke-premium-land.mjs
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
    const dir = mkdtempSync(join(tmpdir(), "land-smoke-"));
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
  const dir = mkdtempSync(join(tmpdir(), "land-smoke-"));
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

const landBundle = bundle(join(root, "src/audio/premiumAutomix.ts"));
const envBundle = bundle(join(root, "src/audio/envelopes.ts"));
const fxBundle = bundle(join(root, "src/dsp/stemEnvelopes.ts"));
const {
  PREMIUM_FEATURES,
  buildLandRecipe,
  snapProgressToBar,
  applyPremiumLand,
} = await import(landBundle.url);
const { defaultParams, playbackRatesAt, pitchCentsAt, volumesAt } =
  await import(envBundle.url);
const { stemFxAt } = await import(fxBundle.url);

let failed = 0;
function check(name, cond, extra = "") {
  if (cond) console.log(`OK  ${name}${extra ? `\n      → ${extra}` : ""}`);
  else {
    console.error(`FAIL ${name}${extra ? `\n      → ${extra}` : ""}`);
    failed++;
  }
}

check("premium catalog ≥ 8", PREMIUM_FEATURES.length >= 8, `${PREMIUM_FEATURES.length} features`);
check(
  "catalog has LAND + HQ + ONE VOCAL",
  PREMIUM_FEATURES.some((f) => f.id === "landExit") &&
    PREMIUM_FEATURES.some((f) => f.id === "hqStream") &&
    PREMIUM_FEATURES.some((f) => f.id === "oneVocal")
);

const snapped = snapProgressToBar(0.53, 32, 120, 1);
check("bar-snap handoff finite", Number.isFinite(snapped) && snapped > 0.1 && snapped < 0.95, `p=${snapped.toFixed(3)}`);

const params = defaultParams();
params.targetBPM = 124;
params.blendDurationSec = 32;
params.handoffAt = 0.52;
params.bassSwapAt = 0.22;
params.rateA = 0.98;
params.rateB = 1.03;
params.pitchCentsB = 100;
params.dsp.mashupMode = "acapellaDrop";
params.dsp.instrAPeak = 0.9;
params.dsp.hpfAPeak = 0.4;
params.dsp.echoAPeak = 0.2;

const fakePlan = {
  params,
  profileA: { bpm: 120 },
  profileB: { bpm: 128 },
  reason: "test",
  story: "TEST → MASHUP",
  archetype: "eqBlend",
  transitionType: "eqBlend",
  beatmatched: true,
  processing: [],
  critic: { ok: true, score: 100, mode: "pass", fixes: [], gates: [] },
};

const applied = applyPremiumLand(fakePlan);
const land = buildLandRecipe(applied.params);
check(
  "LAND handoff snapped + HPF raised",
  applied.params.handoffAt === land.landAt && applied.params.dsp.hpfAPeak >= 0.5,
  `handoff=${applied.params.handoffAt.toFixed(3)} hpf=${applied.params.dsp.hpfAPeak.toFixed(2)}`
);
check(
  "decisions mention Premium LAND",
  applied.params.dsp.decisions.some((d) => String(d).includes("Premium LAND"))
);

// At end of blend: B natural rate/pitch, A silent, HPF up, echo dying.
const end = 0.99;
const rates = playbackRatesAt(end, applied.params);
const cents = pitchCentsAt(end, applied.params);
const vols = volumesAt(end, applied.params);
const fx = stemFxAt(end, applied.params);
check(
  "LAND settle: B rate→1",
  Math.abs(rates.incoming - 1) < 0.02,
  `rateB=${rates.incoming.toFixed(4)}`
);
check(
  "LAND settle: pitch→0",
  Math.abs(cents) < 5,
  `cents=${cents.toFixed(1)}`
);
check(
  "LAND settle: A vol≈0, B≈1",
  vols.outgoing < 0.08 && vols.incoming > 0.9,
  `volA=${vols.outgoing.toFixed(3)} volB=${vols.incoming.toFixed(3)}`
);
check(
  "LAND settle: HPF on A, LPF open on B",
  fx.hpfA >= 0.35 && fx.lpfB < 0.05,
  `hpf=${fx.hpfA.toFixed(2)} lpf=${fx.lpfB.toFixed(2)}`
);

rmSync(landBundle.dir, { recursive: true, force: true });
rmSync(envBundle.dir, { recursive: true, force: true });
rmSync(fxBundle.dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} premium LAND smoke(s) failed`);
  process.exit(1);
}
console.log("\nAll premium LAND smokes passed.");
