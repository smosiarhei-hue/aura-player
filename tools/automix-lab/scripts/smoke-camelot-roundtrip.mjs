/** Regression: estimation and compensation must use the same 24 pitch classes. */
import assert from 'node:assert/strict';
import { buildSync } from 'esbuild';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('..', import.meta.url).pathname);
const source = readFileSync(join(root, 'src/audio/keyCamelot.ts'), 'utf8');
const dir = mkdtempSync(join(tmpdir(), 'camelot-smoke-'));
try {
  const outfile = join(dir, 'key.mjs');
  buildSync({ stdin: { contents: source + '\nexport { pitchClass };\n', resolveDir: root, loader: 'ts' },
    bundle: true, platform: 'node', format: 'esm', outfile });
  const { pitchClass, camelotMatch } = await import(pathToFileURL(outfile).href);
  // Reference pitch classes in number order (C = 0). Independent of implementation tables.
  const expected = {
    A: [8, 3, 10, 5, 0, 7, 2, 9, 4, 11, 6, 1],
    B: [11, 6, 1, 8, 3, 10, 5, 0, 7, 2, 9, 4],
  };
  for (const mode of ['A', 'B']) {
    for (let i = 1; i <= 12; i++) assert.equal(pitchClass(i, mode), expected[mode][i - 1], `${i}${mode}`);
  }
  assert.deepEqual([camelotMatch('4B','9A').isHarmonicallyViable, camelotMatch('4B','9A').pitchShiftCents], [true,100]);
  assert.deepEqual([camelotMatch('9A','4B').isHarmonicallyViable, camelotMatch('9A','4B').pitchShiftCents], [true,-100]);
  assert.deepEqual([camelotMatch('4B','8A').isHarmonicallyViable, camelotMatch('4B','8A').pitchShiftCents], [false,0]);
  assert.equal(camelotMatch('4B','12A',2).isHarmonicallyViable, false);
  assert.equal(camelotMatch('4B','12A',6).pitchShiftCents, 400);
  assert.equal(camelotMatch('8B','8A').isNaturallyCompatible, true);
  console.log('PASS: 24 Camelot pitch classes and bidirectional harmonic regressions');
} finally { rmSync(dir, { recursive: true, force: true }); }
