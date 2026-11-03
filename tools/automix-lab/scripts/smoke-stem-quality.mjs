/**
 * Stem quality smoke — lab Mid/Side bed must tuck lead without killing body/sides.
 *
 *   npm run smoke:stems
 */
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import "web-audio-api/polyfill";
import { OfflineAudioContext } from "web-audio-api";

const root = new URL("..", import.meta.url).pathname;
const require = createRequire(join(root, "package.json"));

function bundle() {
  const esbuild = require("esbuild");
  const dir = mkdtempSync(join(tmpdir(), "stem-smoke-"));
  const entry = join(dir, "entry.ts");
  const out = join(dir, "bundle.mjs");
  writeFileSync(
    entry,
    `export { processBufferStem } from ${JSON.stringify(join(root, "src/dsp/vocalInstrumental.ts"))};`
  );
  esbuild.buildSync({
    entryPoints: [entry],
    bundle: true,
    platform: "node",
    format: "esm",
    outfile: out,
    external: ["web-audio-api"],
  });
  return { dir, out };
}

function energy(buf, band /* 'mid'|'side'|'full' */) {
  const L = buf.getChannelData(0);
  const R = buf.numberOfChannels > 1 ? buf.getChannelData(1) : L;
  let e = 0;
  for (let i = 0; i < buf.length; i++) {
    const mid = (L[i] + R[i]) * 0.5;
    const side = (L[i] - R[i]) * 0.5;
    const v = band === "mid" ? mid : band === "side" ? side : L[i];
    e += v * v;
  }
  return e / Math.max(1, buf.length);
}

function toneBuffer(ctx, { midHz = 1000, sideHz = 330, secs = 0.5, midAmp = 0.4, sideAmp = 0.2 }) {
  const n = Math.floor(ctx.sampleRate * secs);
  const buf = ctx.createBuffer(2, n, ctx.sampleRate);
  const L = buf.getChannelData(0);
  const R = buf.getChannelData(1);
  for (let i = 0; i < n; i++) {
    const t = i / ctx.sampleRate;
    const mid = midAmp * Math.sin(2 * Math.PI * midHz * t);
    const side = sideAmp * Math.sin(2 * Math.PI * sideHz * t);
    L[i] = mid + side;
    R[i] = mid - side;
  }
  return buf;
}

const { dir, out } = bundle();
try {
  const { processBufferStem } = await import(out);
  const ctx = new OfflineAudioContext(2, 44100, 44100);
  const dry = toneBuffer(ctx, { midHz: 1600, sideHz: 400 }); // lead-ish mid
  const bed = processBufferStem(ctx, dry, "instrumental", 0.62, "bed");
  const kill = processBufferStem(ctx, dry, "instrumental", 1.0, "leadKill");
  const vocal = processBufferStem(ctx, dry, "vocal", 0.72);

  const dryMid = energy(dry, "mid");
  const drySide = energy(dry, "side");
  const bedMid = energy(bed, "mid");
  const bedSide = energy(bed, "side");
  const killMid = energy(kill, "mid");
  const vocalSide = energy(vocal, "side");

  console.log(
    JSON.stringify(
      {
        dryMid,
        bedMid,
        bedSide,
        killMid,
        vocalSide,
        bedMidRatio: bedMid / dryMid,
        bedSideRatio: bedSide / drySide,
        killMidRatio: killMid / dryMid,
      },
      null,
      2
    )
  );

  // Soft bed: some mid tuck, sides mostly kept (not ruined instrumental).
  assert.ok(bedMid < dryMid * 0.95, "bed should tuck some mid lead");
  assert.ok(bedMid > dryMid * 0.35, "bed must not nuke groove body");
  assert.ok(bedSide > drySide * 0.85, "bed must keep stereo sides");
  // leadKill is stronger — still not a total mute of all energy.
  assert.ok(killMid < bedMid, "leadKill stronger than bed");
  // Vocal isolate shrinks sides.
  assert.ok(vocalSide < drySide * 0.55, "vocal should cut sides");

  console.log("smoke:stems OK");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
