/**
 * Smoke: modern mashup craft modes (no browser).
 * Run: node scripts/smoke-modern-mashup.mjs
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
    const dir = mkdtempSync(join(tmpdir(), "mash-smoke-"));
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
  const dir = mkdtempSync(join(tmpdir(), "mash-smoke-"));
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

const { dir, url } = bundle(join(root, "src/audio/modernMashup.ts"));
const { chooseModernMashup } = await import(url);

const cases = [
  {
    name: "A instr × B vocal → acapellaDrop",
    run: () => chooseModernMashup(0.2, 0.7, 0.22, 0.52),
    expect: (c) => c.mode === "acapellaDrop" && c.bVocalOpenAt < 0.15 && c.bakeVocalB,
  },
  {
    name: "both vocal → vocalSwap opens B before handoff",
    run: () => chooseModernMashup(0.7, 0.7, 0.22, 0.55),
    expect: (c) =>
      c.mode === "vocalSwap" &&
      c.bakeInstrA &&
      c.bakeInstrB &&
      c.bVocalOpenAt < 0.55 &&
      c.bVocalOpenAt > c.aInstrReadyAt,
  },
  {
    name: "A vocal × B instr → textureBed",
    run: () => chooseModernMashup(0.7, 0.2, 0.25, 0.5),
    expect: (c) => c.mode === "textureBed" && !c.bakeVocalB,
  },
  {
    name: "both instr → instrumentalWash",
    run: () => chooseModernMashup(0.2, 0.2, 0.25, 0.5),
    expect: (c) => c.mode === "instrumentalWash",
  },
];

let failed = 0;
for (const c of cases) {
  const craft = c.run();
  const ok = c.expect(craft);
  console.log(`${ok ? "OK " : "FAIL"} ${c.name}`);
  console.log(`      → ${craft.mode} · open@${(craft.bVocalOpenAt * 100) | 0}% · ${craft.story}`);
  if (!ok) failed++;
}

rmSync(dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} modern mashup smoke(s) failed`);
  process.exit(1);
}
console.log("\nAll modern mashup smokes passed.");
