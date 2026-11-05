/**
 * HTDemucs land bloom: vocal/instrumental stay intact, then the tail is the dry mix.
 */
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const require = createRequire(join(root, "package.json"));
const esbuild = require("esbuild");
const dir = mkdtempSync(join(tmpdir(), "htdemucs-land-"));
const entry = join(dir, "entry.ts");
const out = join(dir, "bundle.mjs");
writeFileSync(
  entry,
  `export { mixLandChannel } from ${JSON.stringify(join(root, "src/audio/neuralStems.ts"))};`
);
await esbuild.build({ entryPoints: [entry], outfile: out, bundle: true, format: "esm", platform: "node" });
const { mixLandChannel } = await import(out);

const dry = new Float32Array([1, 1, 1, 1]);
const stem = new Float32Array([0, 0, 0, 0]);
const vocal = mixLandChannel(dry, stem, 0, 1);
assert.deepEqual(Array.from(vocal), [0, 0, 0, 0]);
const bloom = mixLandChannel(dry, stem, 2, 1);
assert.equal(bloom[0], 0);
assert.equal(bloom[3], 1);
rmSync(dir, { recursive: true, force: true });
console.log("htdemucs land ok");
