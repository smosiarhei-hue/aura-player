/**
 * Smoke: neural Automix cue picker.
 * Run: node scripts/smoke-neural-cue.mjs
 */
import { createRequire } from "node:module";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { writeFileSync, unlinkSync, mkdirSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tmpDir = join(root, ".smoke-tmp");
if (!existsSync(tmpDir)) mkdirSync(tmpDir, { recursive: true });
const outFile = join(tmpDir, "neuralAutomix.mjs");

let failed = 0;
function check(name, ok, detail = "") {
  if (ok) console.log(`OK  ${name}${detail ? `\n      → ${detail}` : ""}`);
  else {
    failed++;
    console.error(`FAIL ${name}${detail ? `\n      → ${detail}` : ""}`);
  }
}

// Bundle the TS module with the TypeScript compiler API via npx esbuild (devDependency optional).
try {
  execFileSync(
    process.execPath,
    [
      join(root, "node_modules/esbuild/bin/esbuild"),
      join(root, "src/audio/neuralAutomix.ts"),
      "--bundle",
      "--format=esm",
      "--platform=neutral",
      `--outfile=${outFile}`,
      "--packages=external",
    ],
    { stdio: "pipe" }
  );
} catch {
  try {
    execFileSync(
      "npx",
      [
        "--yes",
        "esbuild",
        join(root, "src/audio/neuralAutomix.ts"),
        "--bundle",
        "--format=esm",
        "--platform=neutral",
        `--outfile=${outFile}`,
        "--packages=external",
      ],
      { stdio: "pipe", cwd: root }
    );
  } catch (e) {
    console.error("FAIL could not bundle neuralAutomix.ts", e);
    process.exit(1);
  }
}

const neural = await import(pathToFileURL(outFile).href);
const { provisionalProfile, neuralPickMixOut, withNeuralCue } = neural;

const prov = provisionalProfile(200, "test");
check("provisional duration", prov.durationSec === 200);
check("provisional mixOut early enough", prov.mixOutSec < 200 - 10, `mixOut=${prov.mixOutSec}`);
check("provisional mixIn 0", prov.mixInSec === 0);

const energy = Array.from({ length: 800 }, (_, i) => (i > 600 ? 0.4 : 0.7));
const vocal = Array.from({ length: 800 }, (_, i) => (i > 620 ? 0.1 : 0.6));
const profile = {
  ...prov,
  bpm: 120,
  energy,
  vocalPresence: vocal,
  mixOutSec: 155,
};

const transcript = {
  language: "ru",
  source: "yandex-lrc",
  text: "раз два три",
  segments: [
    {
      text: "последняя фраза",
      start: 148,
      end: 152,
      words: [
        { text: "последняя", start: 148, end: 150 },
        { text: "фраза", start: 150.1, end: 152 },
      ],
    },
    {
      text: "ещё крик",
      start: 160,
      end: 163,
      words: [{ text: "ещё", start: 160, end: 161 }],
    },
  ],
};

const cue = neuralPickMixOut(profile, transcript);
check("neural cue finite", Number.isFinite(cue.mixOutSec), JSON.stringify(cue));
check(
  "neural cue in outro window",
  cue.mixOutSec >= 130 && cue.mixOutSec <= 180,
  `mixOut=${cue.mixOutSec}`
);
check("neural has reason", cue.reason.length > 5, cue.reason);

const fused = withNeuralCue(profile, transcript);
check("withNeuralCue updates mixOut", fused.mixOutSec === cue.mixOutSec);

try {
  unlinkSync(outFile);
} catch {
  /* ignore */
}

if (failed) {
  console.error(`\n${failed} neural cue smoke(s) failed`);
  process.exit(1);
}
console.log("\nAll neural cue smokes passed.");
