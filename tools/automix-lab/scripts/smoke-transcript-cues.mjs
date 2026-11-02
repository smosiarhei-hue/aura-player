/**
 * Smoke: Whisper/transcript → Automix cue blending.
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
    const dir = mkdtempSync(join(tmpdir(), "tr-"));
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
  const dir = mkdtempSync(join(tmpdir(), "tr-"));
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

const b = bundle(join(root, "src/audio/transcriptCues.ts"));
const { cueFromTranscript, blendMixOut, wordsAroundTime } = await import(b.url);

let failed = 0;
function check(name, cond, extra = "") {
  if (cond) console.log(`OK  ${name}${extra ? `\n      → ${extra}` : ""}`);
  else {
    console.error(`FAIL ${name}${extra ? `\n      → ${extra}` : ""}`);
    failed++;
  }
}

const duration = 200;
const transcript = {
  language: "ru",
  source: "whisper",
  text: "куплет припев пауза инструментал",
  segments: [
    {
      text: "куплет один два три",
      start: 20,
      end: 40,
      words: [
        { text: "куплет", start: 20, end: 21 },
        { text: "один", start: 21.2, end: 22 },
        { text: "два", start: 22.2, end: 23 },
        { text: "три", start: 23.2, end: 24 },
      ],
    },
    {
      text: "последние слова перед брейком",
      start: 150,
      end: 158,
      words: [
        { text: "последние", start: 150, end: 151 },
        { text: "слова", start: 151.2, end: 152 },
        { text: "перед", start: 152.2, end: 153 },
        { text: "брейком", start: 153.2, end: 154.5 },
      ],
    },
    {
      text: "финальный вокал",
      start: 175,
      end: 185,
      words: [
        { text: "финальный", start: 175, end: 176 },
        { text: "вокал", start: 176.5, end: 178 },
      ],
    },
  ],
};

const cue = cueFromTranscript(transcript, duration, 20);
check(
  "cue prefers phrase gap before late vocal",
  cue.mixOutSec != null && cue.mixOutSec >= 150 && cue.mixOutSec <= 160,
  `mixOut=${cue.mixOutSec?.toFixed(1)} · ${cue.reason}`
);

const blended = blendMixOut(170, cue.mixOutSec, duration, 20);
check("blend uses transcript", blended.usedTranscript, `mixOut=${blended.mixOut.toFixed(1)}`);

const around = wordsAroundTime(transcript, cue.mixOutSec, 4);
check("words around cue", around.length >= 2, around.map((w) => w.text).join(" "));

const empty = cueFromTranscript(
  { language: null, source: "none", text: "", segments: [] },
  duration
);
check("empty transcript → null cue", empty.mixOutSec == null);

rmSync(b.dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} transcript cue smoke(s) failed`);
  process.exit(1);
}
console.log("\nAll transcript cue smokes passed.");
