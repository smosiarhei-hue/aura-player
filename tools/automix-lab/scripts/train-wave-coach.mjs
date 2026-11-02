/**
 * Offline coach train on live «Моя волна» pairs.
 * Decodes tracks → analyze → plan → simulate trail → score → learn offsets.
 *
 *   node scripts/train-wave-coach.mjs [--rounds 6] [--base http://127.0.0.1:43187]
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import decode from "audio-decode";

const root = new URL("..", import.meta.url).pathname;
const require = createRequire(import.meta.url);
const args = process.argv.slice(2);
const rounds = Number(args[args.indexOf("--rounds") + 1] || 6) || 6;
const base = args.includes("--base")
  ? args[args.indexOf("--base") + 1]
  : "http://127.0.0.1:43187";
const coachFile = join(root, ".mix-coach.json");

function bundle(entry) {
  let esbuild;
  try {
    esbuild = require("esbuild");
  } catch {
    const dir = mkdtempSync(join(tmpdir(), "coach-"));
    const out = join(dir, "out.mjs");
    const r = spawnSync(
      "npx",
      [
        "--yes",
        "esbuild",
        entry,
        "--bundle",
        "--platform=node",
        "--format=esm",
        `--outfile=${out}`,
        "--external:audio-decode",
      ],
      { cwd: root, encoding: "utf8" }
    );
    if (r.status !== 0) {
      console.error(r.stderr || r.stdout);
      process.exit(1);
    }
    return { dir, url: pathToFileURL(out).href };
  }
  const dir = mkdtempSync(join(tmpdir(), "coach-"));
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

function toAudioBuffer(decoded) {
  const channelData = decoded.channelData;
  const sampleRate = decoded.sampleRate;
  const length = channelData[0].length;
  return {
    sampleRate,
    length,
    duration: length / sampleRate,
    numberOfChannels: channelData.length,
    getChannelData: (c) => channelData[c],
  };
}

async function api(path, init) {
  const r = await fetch(base + path, init);
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || `${path} ${r.status}`);
  return body;
}

const analyzeB = bundle(join(root, "src/audio/analyzeTrack.ts"));
const planB = bundle(join(root, "src/audio/aiMixEngine.ts"));
const coachB = bundle(join(root, "src/audio/transitionCoach.ts"));
const { analyzeTrackBuffer } = await import(analyzeB.url);
const { planAutomix } = await import(planB.url);
const {
  applyCoachOffsets,
  bakedLeadKill,
  scoreTransition,
  simulateTrail,
  learnFromReport,
  DEFAULT_OFFSETS,
} = await import(coachB.url);

let coach = existsSync(coachFile)
  ? { ...DEFAULT_OFFSETS, ...JSON.parse(readFileSync(coachFile, "utf8")) }
  : { ...DEFAULT_OFFSETS };

const status = await api("/api/ym/status");
if (!status.connected) {
  console.error("Yandex not connected — open player, Device Flow, then retry.");
  process.exit(2);
}

await api("/api/ym/wave/reset", { method: "POST" });
console.log(`Coach train · ${rounds} rounds · login=${status.login}`);
console.log(`start offsets avg=${coach.avgScore} n=${coach.samples}`);

async function nextTrack(retries = 3) {
  let lastErr;
  for (let t = 0; t < retries; t++) {
    try {
      return (await api("/api/ym/wave/next", { method: "POST" })).track;
    } catch (e) {
      lastErr = e;
      console.warn(`    wave/next retry ${t + 1}: ${e.message || e}`);
      await api("/api/ym/wave/reset", { method: "POST" }).catch(() => undefined);
      await new Promise((r) => setTimeout(r, 800 * (t + 1)));
    }
  }
  throw lastErr;
}

for (let i = 0; i < rounds; i++) {
  let aMeta;
  let bMeta;
  try {
    aMeta = await nextTrack();
    bMeta = await nextTrack();
  } catch (e) {
    console.error(`#${i + 1} skip pair: ${e.message || e}`);
    continue;
  }
  console.log(`\n#${i + 1} A ${aMeta.artists} — ${aMeta.title}`);
  console.log(`    B ${bMeta.artists} — ${bMeta.title}`);

  const [aBytes, bBytes] = await Promise.all([
    fetch(base + aMeta.url).then((r) => r.arrayBuffer()),
    fetch(base + bMeta.url).then((r) => r.arrayBuffer()),
  ]);
  const aBuf = toAudioBuffer(await decode(Buffer.from(aBytes)));
  const bBuf = toAudioBuffer(await decode(Buffer.from(bBytes)));
  const profileA = await analyzeTrackBuffer(aBuf, `${aMeta.artists} — ${aMeta.title}`);
  const profileB = await analyzeTrackBuffer(bBuf, `${bMeta.artists} — ${bMeta.title}`);
  const plan = planAutomix(profileA, profileB);
  applyCoachOffsets(plan.params, coach);

  const trail = simulateTrail(plan.params, 96);
  const report = scoreTransition(trail, {
    mode: plan.params.dsp.mashupMode,
    handoffAt: plan.params.handoffAt,
    vocalBAt: plan.params.dsp.vocalBAt,
    instrAAt: plan.params.dsp.instrAAt,
    bassSwapAt: plan.params.bassSwapAt,
    nuclearCarve: bakedLeadKill(plan.params.dsp),
  });

  const before = { ...coach };
  coach = learnFromReport(coach, report);
  writeFileSync(coachFile, JSON.stringify(coach, null, 2));

  await api("/api/mix/log", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      learn: false, // already learned locally; sync file via PUT
      pair: {
        a: `${aMeta.artists} — ${aMeta.title}`,
        b: `${bMeta.artists} — ${bMeta.title}`,
      },
      report,
    }),
  });
  await api("/api/mix/coach", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(coach),
  });

  const failed = report.gates.filter((g) => !g.ok).map((g) => g.id);
  console.log(
    `    mode=${plan.params.dsp.mashupMode} score=${report.score} ${report.ok ? "PASS" : "LEARN"}`
  );
  if (failed.length) console.log(`    fail: ${failed.join(", ")}`);
  if (!report.ok) {
    console.log(
      `    offsets: carve ${before.earlierCarve.toFixed(2)}→${coach.earlierCarve.toFixed(2)} · vocal+ ${before.laterVocalOpen.toFixed(2)}→${coach.laterVocalOpen.toFixed(2)} · quietA ${before.quieterDualA.toFixed(2)}→${coach.quieterDualA.toFixed(2)}`
    );
  }
}

console.log(`\nDone. avgScore=${coach.avgScore} samples=${coach.samples}`);
console.log(`Saved ${coachFile}`);

rmSync(analyzeB.dir, { recursive: true, force: true });
rmSync(planB.dir, { recursive: true, force: true });
rmSync(coachB.dir, { recursive: true, force: true });
