/**
 * Offline ideal Automix exporter.
 *
 * Scans `.ym-cache` for wave-a×wave-b pairs and consecutive wave-n tracks,
 * analyzes each file once (esbuild bundle of analyzeTrack / planAutomix /
 * withNeuralCue), scores with mixCritic + transitionCoach, and renders the
 * best composite on a `web-audio-api` OfflineAudioContext:
 *
 *   ~6s dry A lead-in + full blend (real mashups ≥16s) + ~10s B land.
 *
 *   npm run render:ideal
 *   node scripts/render-ideal-mashup.mjs [--limit N]
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import {
  mkdtempSync,
  rmSync,
  readdirSync,
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
  copyFileSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { spawnSync } from "node:child_process";
import decode from "audio-decode";
import "web-audio-api/polyfill";
import { OfflineAudioContext } from "web-audio-api";

const root = new URL("..", import.meta.url).pathname;
const require = createRequire(join(root, "package.json"));
const cacheDir = join(root, ".ym-cache");
const outDir = join(root, "artifacts");
const optArtifacts = "/opt/cursor/artifacts";
const profileCachePath = join(tmpdir(), "sonivo-ideal-profiles-v4.json");
const LEAD_SEC = 6;
const TAIL_SEC = 10;
const TARGET_DB = -1.0;
const TARGET_LIN = 10 ** (TARGET_DB / 20);

const limitArg = process.argv.includes("--limit")
  ? Number(process.argv[process.argv.indexOf("--limit") + 1])
  : Infinity;

function bundleLab() {
  let esbuild;
  try {
    esbuild = require("esbuild");
  } catch {
    esbuild = null;
  }
  const dir = mkdtempSync(join(tmpdir(), "ideal-"));
  const entry = join(dir, "entry.ts");
  const src = (rel) => JSON.stringify(join(root, rel));
  writeFileSync(
    entry,
    `
export { analyzeTrackBuffer } from ${src("src/audio/analyzeTrack.ts")};
export { planAutomix, vocalLevelNear, recheckMix } from ${src("src/audio/aiMixEngine.ts")};
export { withNeuralCue } from ${src("src/audio/neuralAutomix.ts")};
export { volumesAt, bassGainDbAt, playbackRatesAt, pitchCentsAt, wantsLeadKill, bakedLeadKill } from ${src("src/audio/envelopes.ts")};
export { simulateTrail, scoreTransition, applyCoachOffsets } from ${src("src/audio/transitionCoach.ts")};
export { bakeStemSlice, bakeInstrThenDry, applySidechainDuck, stemFxAt } from ${src("src/dsp/index.ts")};
`
  );
  const out = join(dir, "bundle.mjs");
  if (esbuild) {
    esbuild.buildSync({
      entryPoints: [entry],
      bundle: true,
      platform: "node",
      format: "esm",
      outfile: out,
      external: ["audio-decode", "web-audio-api"],
    });
  } else {
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
        "--external:web-audio-api",
      ],
      { cwd: root, encoding: "utf8" }
    );
    if (r.status !== 0) {
      console.error(r.stderr || r.stdout);
      process.exit(1);
    }
  }
  return { dir, url: pathToFileURL(out).href };
}

const bundled = bundleLab();
const {
  analyzeTrackBuffer,
  planAutomix,
  vocalLevelNear,
  recheckMix,
  withNeuralCue,
  volumesAt,
  bassGainDbAt,
  playbackRatesAt,
  pitchCentsAt,
  wantsLeadKill,
  bakedLeadKill,
  simulateTrail,
  scoreTransition,
  applyCoachOffsets,
  bakeStemSlice,
  bakeInstrThenDry,
  applySidechainDuck,
  stemFxAt,
} = await import(bundled.url);

function listCache() {
  if (!existsSync(cacheDir)) return [];
  return readdirSync(cacheDir)
    .filter((f) => f.endsWith(".mp3") || f.endsWith(".flac") || f.endsWith(".m4a"))
    .map((f) => join(cacheDir, f));
}

function byMtime(a, b) {
  const da = statSync(a).mtimeMs;
  const db = statSync(b).mtimeMs;
  if (da !== db) return da - db;
  return a.localeCompare(b);
}

/** wave-a × wave-b, plus consecutive wave-n in radio (mtime) order. */
function pairCandidates(files) {
  const pairs = [];
  const seen = new Set();
  const push = (a, b, kind) => {
    if (!a || !b || a === b) return;
    const k = `${a}|${b}`;
    if (seen.has(k)) return;
    seen.add(k);
    pairs.push({ a, b, kind });
  };
  const as = files.filter((f) => basename(f).startsWith("wave-a-")).sort();
  const bs = files.filter((f) => basename(f).startsWith("wave-b-")).sort();
  const ab = [];
  for (const a of as) for (const b of bs) {
    const k = `${a}|${b}`;
    if (seen.has(k)) continue;
    seen.add(k);
    ab.push({ a, b, kind: "wave-ab" });
  }
  const ns = files.filter((f) => basename(f).startsWith("wave-n")).sort(byMtime);
  const nn = [];
  for (let i = 0; i + 1 < ns.length; i++) {
    const a = ns[i];
    const b = ns[i + 1];
    const k = `${a}|${b}`;
    if (seen.has(k)) continue;
    seen.add(k);
    nn.push({ a, b, kind: "wave-n" });
  }
  // Pin the previously perfect acapellaDrop cache pair first when present.
  const pinA = files.find((f) => basename(f).includes("51433155"));
  const pinB = files.find((f) => basename(f).includes("130932270"));
  const pinned = [];
  if (pinA && pinB) {
    const k = `${pinA}|${pinB}`;
    if (!seen.has(k)) {
      seen.add(k);
      pinned.push({ a: pinA, b: pinB, kind: "pinned-acapella" });
    }
  }
  // When limited, interleave so Safe Exit A×B doesn't starve wave-n acapella hunts.
  if (Number.isFinite(limitArg)) {
    const half = Math.max(8, Math.floor(limitArg / 2));
    const takeN = nn.slice(0, half);
    const takeA = ab.slice(0, Math.max(0, limitArg - pinned.length - takeN.length));
    return [...pinned, ...takeN, ...takeA].slice(0, limitArg);
  }
  pairs.push(...pinned, ...nn, ...ab);
  if (!pairs.length) {
    const seq = [...files].sort(byMtime);
    for (let i = 0; i + 1 < seq.length; i++) push(seq[i], seq[i + 1], "sequential");
  }
  return pairs;
}

function loadCoach() {
  const p = join(root, ".mix-coach.json");
  if (!existsSync(p)) return null;
  try {
    const raw = JSON.parse(readFileSync(p, "utf8"));
    if (!raw || !(raw.samples > 0)) return null;
    return raw;
  } catch {
    return null;
  }
}

function fileSig(path) {
  const s = statSync(path);
  return `${s.size}:${Math.round(s.mtimeMs)}`;
}

function loadProfileCache() {
  try {
    if (!existsSync(profileCachePath)) return { version: 4, entries: {} };
    const raw = JSON.parse(readFileSync(profileCachePath, "utf8"));
    if (raw?.version !== 4 || !raw.entries) return { version: 4, entries: {} };
    return raw;
  } catch {
    return { version: 4, entries: {} };
  }
}

let profileDisk = loadProfileCache();
const profileMem = new Map();

function saveProfileCache() {
  writeFileSync(profileCachePath, JSON.stringify(profileDisk));
}

function toAudioBufferLike(decoded) {
  const channelData = decoded.channelData.map((ch) =>
    ch instanceof Float32Array ? ch : Float32Array.from(ch)
  );
  const sampleRate = decoded.sampleRate;
  const length = channelData[0].length;
  const ch = channelData.length;
  return {
    sampleRate,
    length,
    duration: length / sampleRate,
    numberOfChannels: ch,
    getChannelData: (c) => channelData[Math.min(c, ch - 1)],
    channelData,
  };
}

async function decodeFile(path) {
  const bytes = readFileSync(path);
  const decoded = await decode(bytes);
  return toAudioBufferLike(decoded);
}

async function ensureProfile(path) {
  if (profileMem.has(path)) return profileMem.get(path);
  const sig = fileSig(path);
  const cached = profileDisk.entries[path];
  if (cached && cached.sig === sig && cached.profile?.durationSec) {
    profileMem.set(path, cached.profile);
    return cached.profile;
  }
  const t0 = Date.now();
  const buf = await decodeFile(path);
  let profile = await analyzeTrackBuffer(buf, basename(path));
  profile = withNeuralCue(profile, null);
  profileMem.set(path, profile);
  profileDisk.entries[path] = { sig, profile };
  saveProfileCache();
  console.log(
    `    analyzed ${basename(path)} ${profile.durationSec.toFixed(0)}s ` +
      `bpm=${profile.bpm} key=${profile.camelotKey ?? "?"} ${(Date.now() - t0) / 1000}s`
  );
  return profile;
}

function windowEnergy(energy, sec, lenSec) {
  if (!energy?.length) return 0;
  const hop = 0.25;
  const a = Math.max(0, Math.floor(sec / hop));
  const b = Math.min(energy.length, Math.ceil((sec + lenSec) / hop));
  if (b <= a) return 0;
  let s = 0;
  for (let i = a; i < b; i++) s += energy[i] || 0;
  return s / (b - a);
}

function energyFloor(energy, t0, t1, win) {
  if (t1 <= t0 + 0.2) return windowEnergy(energy, t0, Math.max(0.2, t1 - t0));
  let floor = Infinity;
  for (let t = t0; t + win <= t1 + 1e-4; t += Math.max(0.25, win * 0.5)) {
    floor = Math.min(floor, windowEnergy(energy, t, win));
  }
  return floor;
}

/**
 * The dry lead is the LEAD_SEC before the cue. A cue whose 3s look fine can
 * still open on a breakdown. Require the whole lead and the next ~2.5s to sit
 * on the same phrase as the loudest nearby bed (the drop, not the hole).
 */
function alignOutgoingCue(profile, cueSec, blendSec) {
  const e = profile.energy || [];
  const dur = profile.durationSec || e.length * 0.25;
  if (e.length < 32) return cueSec;
  const lead = LEAD_SEC;
  const latest = Math.max(lead + 1, dur - Math.max(8, Math.min(blendSec, 24)) - 1);
  const far = Math.min(latest, cueSec + 32);
  const early = Math.max(lead, cueSec - 18);
  let peak = 0.0001;
  for (let t = Math.max(0, early - lead); t < Math.min(dur - 1.5, far + 4); t += 0.5) {
    peak = Math.max(peak, windowEnergy(e, t, 1.5));
  }
  if (peak < 0.08) return cueSec;
  const need = peak * 0.5;
  const leadOk = (t) => {
    if (t < lead * 0.5 || t > latest) return false;
    const floor = energyFloor(e, Math.max(0, t - lead), t, 0.5);
    const ahead = windowEnergy(e, t, 2);
    return floor >= need && ahead >= need * 0.9;
  };
  const snap = (t) => {
    if (!(profile.bpm > 30)) return Math.min(latest, Math.max(0, t));
    const bar = (60 / profile.bpm) * 4;
    const base = Math.round(t / bar) * bar;
    const cands = [base, base + bar, base - bar, base + 2 * bar, t];
    for (const c of cands) {
      if (c >= 0 && c <= latest && leadOk(c)) return c;
    }
    return Math.min(latest, Math.max(0, t));
  };
  if (leadOk(cueSec)) return snap(cueSec);
  for (let t = cueSec; t <= far; t += 0.25) {
    if (leadOk(t)) return snap(t);
  }
  for (let t = cueSec; t >= early; t -= 0.25) {
    if (leadOk(t)) return snap(t);
  }
  return cueSec;
}

/** Move B onto the drop. A long window was hiding a quiet pre-drop under the cue. */
function alignIncomingCue(profile, cueSec, blendSec, tailSec) {
  const e = profile.energy || [];
  const dur = profile.durationSec || e.length * 0.25;
  if (e.length < 32) return cueSec;
  let body = 0;
  let bn = 0;
  for (let i = Math.floor(e.length * 0.3); i < Math.floor(e.length * 0.75); i++) {
    body += e[i] || 0;
    bn++;
  }
  body = bn ? body / bn : 0.5;
  const thresh = Math.max(0.3, body * 0.62);
  const latest = Math.max(0, dur - blendSec - tailSec - 1.2);
  const searchEnd = Math.min(latest, Math.min(dur * 0.45, 80));
  const here = energyFloor(e, cueSec, Math.min(dur, cueSec + 2.4), 1.1);
  const ahead = windowEnergy(e, cueSec, 2.2);
  if (here >= thresh * 0.85 && ahead >= thresh * 0.85) return cueSec;
  const snap = (t) => {
    if (!(profile.bpm > 30)) return t;
    const bar = (60 / profile.bpm) * 4;
    const base = Math.round(t / bar) * bar;
    for (const c of [base, base + bar, base - bar, t]) {
      if (c < 0 || c > latest) continue;
      if (energyFloor(e, c, Math.min(dur, c + 2.4), 1.1) >= thresh * 0.85) return c;
    }
    return t;
  };
  const start = Math.max(0, cueSec - 4);
  for (let t = start; t <= searchEnd; t += 0.25) {
    if (energyFloor(e, t, Math.min(dur, t + 2.4), 1.1) < thresh) continue;
    if (windowEnergy(e, t, 2.2) < thresh * 0.9) continue;
    return Math.min(latest, Math.max(0, snap(t)));
  }
  return cueSec;
}

/** Largest sustained step: 2s before vs 2s after. One-hit transients do not count. */
function maxRiseDb(buf, _hop = 0.5, fromSec = 0) {
  const hop = 0.5;
  const span = 4;
  const dur = buf.length / buf.sampleRate;
  const rms = [];
  for (let t = 0; t + hop <= dur + 1e-6; t += hop) rms.push(sectionRms(buf, t, t + hop));
  let worst = 0;
  let at = 0;
  const start = Math.max(span, Math.floor(Math.max(0, fromSec) / hop));
  for (let i = start; i + span < rms.length; i++) {
    let pre = 0;
    let post = 0;
    for (let k = 0; k < span; k++) {
      pre += rms[i - span + k];
      post += rms[i + k];
    }
    pre /= span;
    post /= span;
    if (pre > 1e-5 && post > 1e-5) {
      const d = 20 * Math.log10(post / pre);
      if (d > worst) {
        worst = d;
        at = i * hop;
      }
    }
  }
  return { db: worst, at };
}

async function scorePair(pair, coachRaw) {
  const profileA = await ensureProfile(pair.a);
  const profileB = await ensureProfile(pair.b);
  const plan = planAutomix(profileA, profileB);
  if (coachRaw) applyCoachOffsets(plan.params, coachRaw);
  const alignedA = alignOutgoingCue(profileA, plan.params.cueASec, plan.params.blendDurationSec);
  if (Math.abs(alignedA - plan.params.cueASec) > 0.35) {
    plan.params.cueASec = alignedA;
    plan.story = `${plan.story} · A@${alignedA.toFixed(1)}s`;
  }
  const alignedB = alignIncomingCue(
    profileB,
    plan.params.cueBSec,
    plan.params.blendDurationSec,
    TAIL_SEC
  );
  if (Math.abs(alignedB - plan.params.cueBSec) > 0.35) {
    plan.params.cueBSec = alignedB;
    plan.story = `${plan.story} · B@${alignedB.toFixed(1)}s`;
  }
  const win = Math.min(12, Math.max(4, plan.params.blendDurationSec));
  const vocalOut = vocalLevelNear(profileA, plan.params.cueASec, win);
  const vocalIn = vocalLevelNear(profileB, plan.params.cueBSec, win);
  const modeNow = plan.params.dsp.mashupMode;
  // Cue moved onto a singing drop — bake the center vocal or the critic hears two leads.
  if (modeNow === "acapellaDrop" && vocalOut >= 0.22) {
    plan.params.dsp.bakeInstrA = true;
    plan.params.dsp.bakeStems = true;
    plan.params.dsp.instrAPeak = Math.max(0.96, plan.params.dsp.instrAPeak || 0);
  }
  if (modeNow === "acapellaDrop") {
    // Empty the "B gated" gap so the lead can be audible on sample 0.
    const at = plan.params.dsp.instrAAt || 0.08;
    plan.params.dsp.vocalBAt = Math.min(plan.params.dsp.vocalBAt || at, at + 0.02);
  }
  // Coach offsets can reopen a clash — Vocal Safe / Bass Surgeon before render.
  recheckMix(plan, vocalOut, vocalIn);
  const critic = plan.critic;
  if (!critic.ok && critic.mode === "pass") critic.mode = "fail";
  const trail = simulateTrail(plan.params, 96);
  const coach = scoreTransition(trail, {
    mode: plan.params.dsp.mashupMode,
    handoffAt: plan.params.handoffAt,
    vocalBAt: plan.params.dsp.vocalBAt,
    instrAAt: plan.params.dsp.instrAAt,
    bassSwapAt: plan.params.bassSwapAt,
    nuclearCarve: bakedLeadKill(plan.params.dsp),
    naturalBed: modeNow === "acapellaDrop" && vocalOut < 0.28 && !bakedLeadKill(plan.params.dsp),
  });
  const mode = plan.params.dsp.mashupMode;
  // Safe Exit scores easy coach 100s — demote so real mashups can win the export.
  const modeBias =
    mode === "acapellaDrop"
      ? 18
      : mode === "textureBed"
        ? 10
        : mode === "instrumentalWash"
          ? 6
          : mode === "safeExit"
            ? -22
            : 0;
  const blendBias = Math.min(8, Math.max(0, ((plan.params.blendDurationSec || 0) - 12) * 0.4));
  const rank = critic.score * 0.45 + coach.score * 0.4 + modeBias + blendBias;
  const composite = Math.round(Math.max(0, Math.min(100, rank)));
  return {
    ...pair,
    profileA,
    profileB,
    plan,
    critic,
    coach,
    composite,
    rank,
    vocalOut,
    vocalIn,
    mode,
  };
}

function modeTie(mode) {
  if (mode === "acapellaDrop") return 3;
  if (mode === "textureBed") return 2;
  if (mode === "instrumentalWash") return 1;
  return 0;
}

function tempoStretch(hit) {
  const ra = hit.plan?.params?.rateA || 1;
  const rb = hit.plan?.params?.rateB || 1;
  return Math.max(Math.abs(Math.log2(ra)), Math.abs(Math.log2(rb)));
}

/** Higher is better. Passing gates outrank a hotter score that fails. */
function rankOf(hit) {
  const pass = hit.critic.ok && hit.coach.ok ? 1 : 0;
  // ~240¢ of beatmatch pitch (rate 1.15) costs more than a few composite points.
  const stretchPenalty = Math.min(28, tempoStretch(hit) * 140);
  const blend = hit.plan?.params?.blendDurationSec || 0;
  const blendBonus = Math.min(6, Math.max(0, blend - 10) * 0.25);
  const score = typeof hit.rank === "number" ? hit.rank : hit.composite;
  return pass * 200 + score - stretchPenalty + blendBonus + modeTie(hit.mode) * 8;
}

function better(a, b) {
  return rankOf(a) > rankOf(b);
}

function resample(src, fromRate, toRate) {
  if (fromRate === toRate) return src;
  const n = Math.max(1, Math.floor((src.length * toRate) / fromRate));
  const out = new Float32Array(n);
  const ratio = fromRate / toRate;
  for (let i = 0; i < n; i++) {
    const x = i * ratio;
    const i0 = Math.floor(x);
    const i1 = Math.min(src.length - 1, i0 + 1);
    const f = x - i0;
    const a = src[i0] || 0;
    const b = src[i1] || 0;
    out[i] = a + (b - a) * f;
  }
  return out;
}

function makeStereo(ctx, decoded, sampleRate) {
  const ch0 = decoded.getChannelData(0);
  const ch1 = decoded.numberOfChannels > 1 ? decoded.getChannelData(1) : ch0;
  const L = resample(ch0, decoded.sampleRate, sampleRate);
  const R = resample(ch1, decoded.sampleRate, sampleRate);
  const len = Math.min(L.length, R.length);
  const buf = ctx.createBuffer(2, len, sampleRate);
  putChannel(buf, 0, L.subarray(0, len));
  putChannel(buf, 1, R.subarray(0, len));
  return buf;
}

function putChannel(buf, channel, src) {
  const data = src instanceof Float32Array ? src : Float32Array.from(src);
  const dst = buf.getChannelData(channel);
  const n = Math.min(data.length, dst.length);
  if (n > 0) dst.set(data.subarray(0, n));
}

function scheduleParam(param, pts) {
  if (!pts.length) return;
  const cleaned = [];
  for (const p of pts) {
    const t = cleaned.length ? Math.max(p.t, cleaned[cleaned.length - 1].t + 1e-4) : Math.max(0, p.t);
    cleaned.push({ t, v: Number.isFinite(p.v) ? p.v : 0 });
  }
  param.setValueAtTime(cleaned[0].v, cleaned[0].t);
  for (let i = 1; i < cleaned.length; i++) {
    param.linearRampToValueAtTime(cleaned[i].v, cleaned[i].t);
  }
}

function timelineTimes(total, marks) {
  const times = new Set(marks.filter((t) => t >= 0 && t <= total + 1e-6));
  const dt = 0.04;
  for (let t = 0; t <= total + 1e-9; t += dt) times.add(Math.min(total, Math.round(t * 1000) / 1000));
  times.add(total);
  return [...times].sort((a, b) => a - b);
}

function createEcho(ctx, bpm) {
  const input = ctx.createGain();
  const output = ctx.createGain();
  const dry = ctx.createGain();
  const wet = ctx.createGain();
  const delay = ctx.createDelay(1.5);
  const fb = ctx.createGain();
  const filter = ctx.createBiquadFilter();
  filter.type = "lowpass";
  filter.frequency.setValueAtTime(Math.min(4200, ctx.sampleRate * 0.45), 0);
  filter.Q.setValueAtTime(0.5, 0);
  const beat = bpm > 30 ? 60 / bpm : 0.5;
  delay.delayTime.setValueAtTime(Math.min(1.2, Math.max(0.05, beat * 0.75)), 0);
  input.connect(dry);
  dry.connect(output);
  input.connect(delay);
  delay.connect(filter);
  filter.connect(wet);
  wet.connect(output);
  filter.connect(fb);
  fb.connect(delay);
  return { input, output, dry, wet, fb };
}

function hpfHz(amount, sr) {
  const a = Math.min(1, Math.max(0, amount));
  return Math.min(sr * 0.45, Math.max(20, 20 * 300 ** a));
}

function lpfHz(amount, sr) {
  const a = Math.min(1, Math.max(0, amount));
  return Math.min(sr * 0.45, Math.max(200, 20000 / 25 ** a));
}

function sectionRms(buf, startSec, endSec) {
  const sr = buf.sampleRate;
  const i0 = Math.max(0, Math.floor(startSec * sr));
  const i1 = Math.min(buf.length, Math.floor(endSec * sr));
  if (i1 <= i0 + 8) return 0;
  const L = buf.getChannelData(0);
  const R = buf.numberOfChannels > 1 ? buf.getChannelData(1) : L;
  let s = 0;
  for (let i = i0; i < i1; i++) s += L[i] * L[i] + R[i] * R[i];
  return Math.sqrt(s / (2 * (i1 - i0)));
}

function peakOf(buf) {
  let peak = 0;
  for (let c = 0; c < buf.numberOfChannels; c++) {
    const d = buf.getChannelData(c);
    for (let i = 0; i < d.length; i++) {
      const a = Math.abs(d[i]);
      if (a > peak) peak = a;
    }
  }
  return peak;
}

function truePeak4(buf) {
  let tp = 0;
  for (let c = 0; c < buf.numberOfChannels; c++) {
    const d = buf.getChannelData(c);
    for (let i = 0; i < d.length - 1; i++) {
      const a = d[i];
      const b = d[i + 1];
      for (let k = 0; k < 4; k++) {
        const s = Math.abs(a + ((b - a) * k) / 4);
        if (s > tp) tp = s;
      }
    }
  }
  return tp;
}

function peakNormalize(buf, target = TARGET_LIN) {
  const peak = peakOf(buf);
  if (peak < 1e-8) return { peakBefore: peak, gain: 1, truePeak: 0 };
  let g = target / peak;
  for (let c = 0; c < buf.numberOfChannels; c++) {
    const d = buf.getChannelData(c);
    for (let i = 0; i < d.length; i++) d[i] *= g;
  }
  // Linear true-peak trim only — a soft knee here was a second distortion stage.
  const tp = truePeak4(buf);
  if (tp > target * 1.001) {
    const trim = target / tp;
    g *= trim;
    for (let c = 0; c < buf.numberOfChannels; c++) {
      const d = buf.getChannelData(c);
      for (let i = 0; i < d.length; i++) d[i] *= trim;
    }
  }
  return { peakBefore: peak, gain: g, truePeak: truePeak4(buf) };
}

/**
 * When the carved bed may replace dry A. Doing it at blend-start, while B is
 * still quiet, strips the center and leaves an anti-phase side image — a hole
 * of more than 8 dB, not a musical dip.
 */
function carveHandoffProgress(params) {
  let fallback = 0.32;
  for (let i = 0; i <= 500; i++) {
    const prog = i / 500;
    const v = volumesAt(prog, params);
    const b = bassGainDbAt(prog, params);
    if (v.incoming >= 0.45 && b.incoming > -5.5) return Math.min(0.86, prog);
    if (v.incoming >= 0.5) fallback = Math.min(fallback, prog);
  }
  return Math.min(0.8, Math.max(0.12, fallback));
}

/**
 * Slow gain ride after the mix. Moves invite / mashup / LAND toward the lead
 * without seam fades back to unity (those re-opened the hole) and without
 * more than ~6.5 dB of makeup.
 */
function continuityRide(buf, leadT0, leadT1) {
  // 70th percentile, not the mean — a breakdown inside the lead must not
  // become the target and duck the rest of the mashup toward the hole.
  const leadWindows = [];
  for (let t = leadT0; t + 0.25 <= leadT1; t += 0.25) {
    const r = sectionRms(buf, t, t + 0.25);
    if (r > 1e-7) leadWindows.push(r);
  }
  leadWindows.sort((a, b) => a - b);
  const lead =
    (leadWindows.length
      ? leadWindows[Math.min(leadWindows.length - 1, Math.floor(0.7 * (leadWindows.length - 1)))]
      : sectionRms(buf, leadT0, leadT1)) || 0.05;
  const sr = buf.sampleRate;
  const n = buf.length;
  const hop = Math.max(1, Math.floor(0.05 * sr));
  const win = Math.max(hop * 4, Math.floor(1.35 * sr));
  const raw = [];
  for (let c = 0; c < n; c += hop) {
    const a = Math.max(0, c - Math.floor(win / 2));
    const b = Math.min(n, a + win);
    const r = sectionRms(buf, a / sr, b / sr);
    let g = 1;
    const t = c / sr;
    if (t >= leadT1 && r > 1e-7) {
      let db = 20 * Math.log10((lead * 0.97) / r);
      if (db > 6.5) db = 6.5;
      if (db < -6.5) db = -6.5;
      const fade = Math.min(1, (t - leadT1) / 0.6);
      const ease = fade * fade * (3 - 2 * fade);
      g = 1 + (10 ** (db / 20) - 1) * ease;
    }
    raw.push(g);
  }
  const radius = Math.max(1, Math.round((0.4 * sr) / hop));
  const smooth = raw.map((_, i) => {
    let s = 0;
    let w = 0;
    for (let k = -radius; k <= radius; k++) {
      const j = i + k;
      if (j < 0 || j >= raw.length) continue;
      const wk = radius + 1 - Math.abs(k);
      s += raw[j] * wk;
      w += wk;
    }
    return s / Math.max(w, 1e-9);
  });
  const oL = buf.getChannelData(0);
  const oR = buf.numberOfChannels > 1 ? buf.getChannelData(1) : oL;
  for (let i = 0; i < n; i++) {
    const x = i / hop;
    const i0 = Math.min(smooth.length - 1, Math.max(0, Math.floor(x)));
    const i1 = Math.min(smooth.length - 1, i0 + 1);
    const f = Math.min(1, Math.max(0, x - i0));
    const g = smooth[i0] + (smooth[i1] - smooth[i0]) * f;
    oL[i] *= g;
    if (oR !== oL) oR[i] *= g;
  }
  return lead;
}

function encodeWav(buffer) {
  const ch = buffer.numberOfChannels;
  const sr = buffer.sampleRate;
  const n = buffer.length;
  const dataSize = n * ch * 2;
  const out = Buffer.allocUnsafe(44 + dataSize);
  out.write("RIFF", 0);
  out.writeUInt32LE(36 + dataSize, 4);
  out.write("WAVE", 8);
  out.write("fmt ", 12);
  out.writeUInt32LE(16, 16);
  out.writeUInt16LE(1, 20);
  out.writeUInt16LE(ch, 22);
  out.writeUInt32LE(sr, 24);
  out.writeUInt32LE(sr * ch * 2, 28);
  out.writeUInt16LE(ch * 2, 32);
  out.writeUInt16LE(16, 34);
  out.write("data", 36);
  out.writeUInt32LE(dataSize, 40);
  const channels = [];
  for (let c = 0; c < ch; c++) channels.push(buffer.getChannelData(c));
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < ch; c++) {
      let s = channels[c][i] || 0;
      if (s > 1) s = 1;
      else if (s < -1) s = -1;
      out.writeInt16LE((s * 32767) | 0, o);
      o += 2;
    }
  }
  return out;
}

function regionRms(decoded, t0, t1) {
  const sr = decoded.sampleRate;
  const n = decoded.length;
  const i0 = Math.max(0, Math.floor(Math.min(t0, t1) * sr));
  const i1 = Math.min(n, Math.floor(Math.max(t0, t1) * sr));
  if (i1 <= i0 + 32) return 0;
  const L = decoded.getChannelData(0);
  const R = decoded.numberOfChannels > 1 ? decoded.getChannelData(1) : L;
  let s = 0;
  for (let i = i0; i < i1; i++) {
    const m = 0.5 * (L[i] + R[i]);
    s += m * m;
  }
  return Math.sqrt(s / (i1 - i0));
}

function rmsFloor(decoded, t0, t1, win) {
  const dur = decoded.duration || decoded.length / decoded.sampleRate;
  const end = Math.min(dur - 0.05, t1);
  const start = Math.max(0, t0);
  if (end <= start + 0.15) return regionRms(decoded, start, Math.max(start + 0.15, end));
  let floor = Infinity;
  for (let t = start; t + win <= end + 1e-4; t += 0.2) {
    floor = Math.min(floor, regionRms(decoded, t, Math.min(dur - 0.02, t + win)));
  }
  return floor;
}

/**
 * Park a cue so the named window is within ~7 dB of the loudest nearby phrase.
 * Outgoing watches the dry lead before the cue; incoming watches the first
 * seconds after it (a pre-drop must not hide inside a long average).
 */
function parkOnPhrase(decoded, cue, roomEnd, { pre = 0, post = 2.4 } = {}) {
  const dur = decoded.duration || decoded.length / decoded.sampleRate;
  const end = Math.max(cue, Math.min(roomEnd, dur - post - 0.2));
  let peak = 1e-8;
  const lo = Math.max(0, cue - 18);
  const hi = Math.min(dur - 1.6, cue + 26);
  for (let t = lo; t <= hi; t += 0.5) peak = Math.max(peak, regionRms(decoded, t, t + 1.4));
  const need = peak * 10 ** (-6.5 / 20);
  const ok = (t) => {
    if (t < 0 || t > end) return false;
    const before = pre > 0.2 ? rmsFloor(decoded, t - pre, t, 0.45) : peak;
    const after = rmsFloor(decoded, t, t + post, 0.45);
    return before >= need && after >= need * 0.9;
  };
  if (ok(cue)) return cue;
  for (let t = cue; t <= Math.min(end, cue + 24); t += 0.2) {
    if (ok(t)) return t;
  }
  for (let t = cue; t >= Math.max(0, cue - 16); t -= 0.2) {
    if (ok(t)) return t;
  }
  return Math.max(0, Math.min(end, cue));
}

/** Seconds of source from `cue` that stay within 8 dB of the phrase we parked on. */
function loudRunway(decoded, cue, maxSec) {
  const dur = decoded.duration || decoded.length / decoded.sampleRate;
  const ref = regionRms(decoded, cue, Math.min(dur - 0.05, cue + 2.5));
  if (!(ref > 1e-5)) return Math.max(0, maxSec);
  const limit = ref * 10 ** (-8 / 20);
  const end = Math.min(dur - 0.3, cue + maxSec);
  let last = 0.4;
  for (let t = cue; t + 0.5 <= end; t += 0.25) {
    if (regionRms(decoded, t, t + 0.5) < limit) break;
    last = t + 0.5 - cue;
  }
  return last;
}

/**
 * Beatmatch without pitching. playbackRate would drop a 15% tempo lock by
 * hundreds of cents; rubberband keeps the formants and we play the result at 1×.
 */
function pitchSafeStretch(decoded, tempo) {
  const rate = Number(tempo);
  if (!(rate > 0.5 && rate < 1.5) || Math.abs(rate - 1) < 0.012) {
    return { decoded, ratio: 1, applied: false };
  }
  const sr = decoded.sampleRate;
  const ch = Math.max(1, decoded.numberOfChannels || 1);
  const n = decoded.length;
  const raw = Buffer.allocUnsafe(n * ch * 4);
  const planes = [];
  for (let c = 0; c < ch; c++) planes.push(decoded.getChannelData(Math.min(c, decoded.numberOfChannels - 1)));
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < ch; c++) raw.writeFloatLE(planes[c][i] || 0, (i * ch + c) * 4);
  }
  const dir = mkdtempSync(join(tmpdir(), "rb-"));
  const inPath = join(dir, "in.f32");
  const outPath = join(dir, "out.f32");
  try {
    writeFileSync(inPath, raw);
    const ff = spawnSync(
      "ffmpeg",
      [
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "f32le",
        "-ar",
        String(sr),
        "-ac",
        String(ch),
        "-i",
        inPath,
        "-af",
        `rubberband=tempo=${rate.toFixed(6)}:formant=preserved:pitchq=quality:transients=crisp`,
        "-c:a",
        "pcm_f32le",
        "-f",
        "f32le",
        outPath,
      ],
      { encoding: "utf8" }
    );
    if (ff.status !== 0 || !existsSync(outPath)) {
      console.warn("rubberband skip:", (ff.stderr || ff.stdout || "").slice(0, 240));
      return { decoded, ratio: 1, applied: false };
    }
    const out = readFileSync(outPath);
    const frames = Math.floor(out.length / (4 * ch));
    if (frames < sr) return { decoded, ratio: 1, applied: false };
    const channelData = [];
    for (let c = 0; c < ch; c++) channelData.push(new Float32Array(frames));
    for (let i = 0; i < frames; i++) {
      for (let c = 0; c < ch; c++) channelData[c][i] = out.readFloatLE((i * ch + c) * 4);
    }
    const stretched = {
      sampleRate: sr,
      length: frames,
      duration: frames / sr,
      numberOfChannels: ch,
      getChannelData: (c) => channelData[Math.min(c, ch - 1)],
      channelData,
    };
    return { decoded: stretched, ratio: stretched.duration / (decoded.duration || n / sr), applied: true };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function fitWindow(durA, durB, wantBlend, mode) {
  // Ideal mashup needs an audible story — never ship a blink-cut as the hero.
  const minBlend = mode === "safeExit" ? 6 : mode === "acapellaDrop" ? 20 : 16;
  let blend = Math.min(48, Math.max(minBlend, wantBlend));
  const maxBlend = Math.min(durA - 0.4, durB - TAIL_SEC - 0.4);
  if (!(maxBlend >= 4)) {
    throw new Error(`outro too short for mashup (A ${durA.toFixed(1)}s B ${durB.toFixed(1)}s)`);
  }
  blend = Math.min(blend, maxBlend);
  return blend;
}

/**
 * Offline graph:
 *   A: source → lowshelf(bassGainDbAt) → HPF → optional echo → gain(volumesAt)
 *   B: source → lowshelf → optional mid duck → LPF → gain
 * playbackRate / detune follow playbackRatesAt / pitchCentsAt.
 */
async function renderMashup(hit) {
  let decodedA = await decodeFile(hit.a);
  let decodedB = await decodeFile(hit.b);
  const sr = decodedA.sampleRate;
  const p = hit.plan.params;
  const dsp = p.dsp;
  const durA = decodedA.duration;
  const durBsec = decodedB.duration;
  const mode = dsp.mashupMode || "unknown";
  // Promote hard cuts to a real blend curve for the offline ideal export.
  if (p.archetype === "cutOnOne" && mode !== "safeExit") {
    p.archetype = "smartCrossfade";
    p.outgoingVolumeHold = Math.max(0.4, p.outgoingVolumeHold || 0.4);
    p.incomingVolumeLag = Math.min(0.1, p.incomingVolumeLag || 0.1);
    p.handoffAt = Math.max(0.48, Math.min(0.62, p.handoffAt || 0.55));
    p.blendDurationSec = Math.max(20, p.blendDurationSec || 16);
  }
  let blend = fitWindow(durA, durBsec, p.blendDurationSec, mode);
  let cueA = Math.min(Math.max(0, p.cueASec), Math.max(0, durA - blend - 0.12));
  let cueB = Math.min(Math.max(0, p.cueBSec), Math.max(0, durBsec - blend - TAIL_SEC - 0.12));
  const cueA0 = cueA;
  const cueB0 = cueB;
  cueA = parkOnPhrase(decodedA, cueA, Math.max(0, durA - blend - 0.3), { pre: LEAD_SEC, post: 2.6 });
  cueB = parkOnPhrase(decodedB, cueB, Math.max(0, durBsec - blend - TAIL_SEC - 0.3), {
    pre: 0,
    post: 2.6,
  });
  if (Math.abs(cueA - cueA0) > 0.05 || Math.abs(cueB - cueB0) > 0.05) {
    console.log(
      `  cue park A ${cueA0.toFixed(2)}→${cueA.toFixed(2)} B ${cueB0.toFixed(2)}→${cueB.toFixed(2)} (phrase, not breakdown)`
    );
  }
  const musicalCueA = cueA;
  const musicalCueB = cueB;
  const runwaySrc = loudRunway(decodedB, musicalCueB, blend + TAIL_SEC + 1);
  const musicalRateA = p.rateA || 1;
  const musicalRateB = p.rateB || 1;
  let stretchA = { applied: false, ratio: 1 };
  let stretchB = { applied: false, ratio: 1 };
  if (Math.abs(musicalRateA - 1) >= 0.012) {
    stretchA = pitchSafeStretch(decodedA, musicalRateA);
    if (stretchA.applied) {
      decodedA = stretchA.decoded;
      cueA = musicalCueA * stretchA.ratio;
      p.rateA = 1;
    }
  }
  if (Math.abs(musicalRateB - 1) >= 0.012) {
    console.log(`  rubberband B tempo ×${musicalRateB.toFixed(3)} (pitch preserved)`);
    stretchB = pitchSafeStretch(decodedB, musicalRateB);
    if (stretchB.applied) {
      decodedB = stretchB.decoded;
      cueB = musicalCueB * stretchB.ratio;
      p.rateB = 1;
    }
  }
  hit.musical = {
    cueA: musicalCueA,
    cueB: musicalCueB,
    rateA: musicalRateA,
    rateB: musicalRateB,
    pitchSafe: stretchA.applied || stretchB.applied,
  };

  const outRun = runwaySrc / (stretchB.applied ? musicalRateB : 1);
  if (outRun < blend + 2.5) {
    const capped = Math.max(12, Math.min(blend, outRun - 2.5));
    if (capped + 0.4 < blend) {
      console.log(`  trim blend ${blend.toFixed(1)}→${capped.toFixed(1)}s (B phrase stays loud)`);
      blend = capped;
    }
  }
  const tailSec = Math.min(TAIL_SEC, Math.max(2.5, outRun - blend));
  if (tailSec + 0.4 < TAIL_SEC) {
    console.log(`  trim tail ${TAIL_SEC}→${tailSec.toFixed(1)}s (stay on B's phrase)`);
  }

  const leadSamples = Math.round(LEAD_SEC * sr);
  const blendSamples = Math.round(blend * sr);
  const tailSamples = Math.round(tailSec * sr);
  const totalSamples = leadSamples + blendSamples + tailSamples;
  const blendStart = leadSamples / sr;
  const blendDur = blendSamples / sr;
  const total = totalSamples / sr;
  const blendEnd = blendStart + blendDur;

  const ctx = new OfflineAudioContext(2, totalSamples, sr);
  const aFull = makeStereo(ctx, decodedA, sr);
  const bFull = makeStereo(ctx, decodedB, sr);

  const leadActual = Math.min(LEAD_SEC, cueA);
  const leadPad = LEAD_SEC - leadActual;
  // ~100 ms dry→bed overlap. A longer sum of dry + mid/side carve cancels the center.
  const bedFade = 0.1;
  // Bass-shelf wait stacks A's dry vocal on B for seconds. Carving at
  // blend-start, while B is still near silence, is the >8 dB hole.
  // Swap once B's fader is actually loud.
  let pBed = carveHandoffProgress(p);
  if (mode === "acapellaDrop") {
    let loud = pBed;
    for (let i = 0; i <= 500; i++) {
      const prog = i / 500;
      if (volumesAt(prog, p).incoming >= 0.62) {
        loud = prog;
        break;
      }
    }
    pBed = Math.min(pBed, Math.max(0.015, loud));
  }
  const tBed = Math.min(blendEnd - 0.2, blendStart + pBed * blendDur);
  const tBed0 = Math.max(blendStart, tBed - bedFade);

  let aBlendBuf = aFull;
  let aBlendOffset = cueA;
  let bPlayBuf = bFull;
  let bOffset = cueB;
  let bakedA = false;

  const leadKill = wantsLeadKill(dsp);
  if (leadKill || dsp.bakeInstrA) {
    const amt = leadKill
      ? Math.min(1, Math.max(0.94, dsp.instrAPeak || 0.95))
      : Math.min(1, Math.max(0.35, dsp.instrAPeak || 0.85));
    const carve = leadKill ? "leadKill" : "bed";
    aBlendBuf = bakeStemSlice(ctx, aFull, cueA, blendDur + 3, "instrumental", amt, carve);
    aBlendOffset = 0;
    bakedA = true;
  }

  if (leadKill || (dsp.bakeInstrB && (dsp.instrBPeak || 0) >= 0.5)) {
    // B is fully dry before A's center is carved. untilSec is buffer time;
    // playbackRate below 1 runs the output clock ahead of the bake, so an
    // output-time offset left B still carved after A had dropped its vocal
    // and the middle fell more than 8 dB.
    const leaveDur = Math.max(0, tBed0 - blendStart);
    let bufAtLeave = 0;
    const steps = 240;
    const dt = leaveDur / steps;
    for (let i = 0; i < steps; i++) {
      const t0 = blendStart + dt * (i + 0.5);
      const prog = Math.min(1, Math.max(0, (t0 - blendStart) / Math.max(1e-6, blendDur)));
      bufAtLeave += playbackRatesAt(prog, p).incoming * dt;
    }
    const untilSec = Math.min(blendDur * 0.85, Math.max(0.05, bufAtLeave - 0.06));
    bPlayBuf = bakeInstrThenDry(
      ctx,
      bFull,
      cueB,
      blendDur + TAIL_SEC + 3,
      untilSec,
      Math.min(0.9, Math.max(0.75, dsp.instrBPeak || 0.8)),
      "bed"
    );
    bOffset = 0;
  }

  if ((dsp.sidechainA || 0) > 0.05 && bakedA) {
    const key =
      bOffset === 0
        ? bPlayBuf
        : bakeStemSlice(ctx, bFull, cueB, blendDur + 2, "dry", 0);
    try {
      aBlendBuf = applySidechainDuck(aBlendBuf, key, dsp.sidechainA, ctx);
    } catch (err) {
      console.warn("sidechain skip:", err?.message || err);
    }
  }

  const bpm = p.targetBPM || hit.profileA.bpm || 120;
  const useEcho = (dsp.echoAPeak || 0) > 0.02;
  const useDuck = (dsp.vocalDuckBDb || 0) < -0.2;

  const bassA = ctx.createBiquadFilter();
  bassA.type = "lowshelf";
  bassA.frequency.setValueAtTime(120, 0);
  const hpf = ctx.createBiquadFilter();
  hpf.type = "highpass";
  hpf.Q.setValueAtTime(0.707, 0);
  hpf.frequency.setValueAtTime(20, 0);
  const gainA = ctx.createGain();
  const echo = useEcho ? createEcho(ctx, bpm) : null;

  bassA.connect(hpf);
  if (echo) {
    hpf.connect(echo.input);
    echo.output.connect(gainA);
  } else {
    hpf.connect(gainA);
  }
  gainA.connect(ctx.destination);

  const bassB = ctx.createBiquadFilter();
  bassB.type = "lowshelf";
  bassB.frequency.setValueAtTime(120, 0);
  const lpf = ctx.createBiquadFilter();
  lpf.type = "lowpass";
  lpf.Q.setValueAtTime(0.707, 0);
  lpf.frequency.setValueAtTime(Math.min(20000, sr * 0.45), 0);
  let bMid = null;
  if (useDuck) {
    bMid = ctx.createBiquadFilter();
    bMid.type = "peaking";
    bMid.frequency.setValueAtTime(1400, 0);
    bMid.Q.setValueAtTime(0.85, 0);
    bMid.gain.setValueAtTime(0, 0);
  }
  const gainB = ctx.createGain();
  if (bMid) {
    bassB.connect(bMid);
    bMid.connect(lpf);
  } else {
    bassB.connect(lpf);
  }
  lpf.connect(gainB);
  gainB.connect(ctx.destination);

  const srcLead = ctx.createBufferSource();
  const srcBlendA = bakedA ? ctx.createBufferSource() : null;
  const srcB = ctx.createBufferSource();

  if (!bakedA) {
    srcLead.buffer = aFull;
    srcLead.connect(bassA);
  } else {
    srcLead.buffer = aFull;
    // Dry lead stays full-band — its own gain, not the blend HPF/bass curve.
    const leadGain = ctx.createGain();
    srcLead.connect(leadGain);
    leadGain.connect(ctx.destination);
    srcLead._leadGain = leadGain;
    srcBlendA.buffer = aBlendBuf;
    srcBlendA.connect(bassA);
  }
  srcB.buffer = bPlayBuf;
  srcB.connect(bassB);

  const endEnvP = 1;
  const vEnd = volumesAt(endEnvP, p);
  const bEnd = bassGainDbAt(endEnvP, p);
  const rEnd = playbackRatesAt(endEnvP, p);
  const pitchEnd = pitchCentsAt(endEnvP, p);

  const times = timelineTimes(total, [
    0,
    leadPad,
    leadPad + 0.01,
    blendStart,
    tBed0,
    tBed0 + bedFade * 0.5,
    tBed,
    blendEnd,
    blendEnd + 0.08,
    Math.max(0, total - 0.015),
    total,
  ]);

  const volA = [];
  const volB = [];
  const volLead = [];
  const bassOut = [];
  const bassIn = [];
  const rateA = [];
  const rateB = [];
  const pitch = [];
  const hpfPts = [];
  const lpfPts = [];
  const duckPts = [];
  const echoWet = [];
  const echoFb = [];
  const echoDry = [];

  for (const t of times) {
    let env;
    if (t < blendStart - 1e-6) {
      env = {
        volA: 1,
        volB: 0,
        bassA: 0,
        bassB: 0,
        rateA: 1,
        rateB: 1,
        pitch: 0,
        hpf: 0,
        lpf: 0,
        echo: 0,
        duck: 0,
      };
    } else if (t > blendEnd + 1e-6) {
      const u = Math.min(1, (t - blendEnd) / 0.08);
      env = {
        volA: vEnd.outgoing * (1 - u),
        volB: vEnd.incoming + (1 - vEnd.incoming) * u,
        bassA: bEnd.outgoing * (1 - u),
        bassB: bEnd.incoming * (1 - u),
        rateA: rEnd.outgoing + (1 - rEnd.outgoing) * u,
        rateB: rEnd.incoming + (1 - rEnd.incoming) * u,
        pitch: pitchEnd * (1 - u),
        hpf: 0,
        lpf: 0,
        echo: 0,
        duck: 0,
      };
    } else {
      const prog = Math.min(1, Math.max(0, (t - blendStart) / blendDur));
      const v = volumesAt(prog, p);
      const b = bassGainDbAt(prog, p);
      const r = playbackRatesAt(prog, p);
      const fx = stemFxAt(prog, p);
      let bassB = b.incoming;
      if (
        (p.dsp.mashupMode === "textureBed" || p.dsp.mashupMode === "instrumentalWash") &&
        prog < 0.3
      ) {
        const u = prog / 0.3;
        const ease = u * u * (3 - 2 * u);
        bassB = b.incoming * (1 - ease);
      }
      env = {
        volA: v.outgoing,
        volB: v.incoming,
        bassA: b.outgoing,
        bassB,
        rateA: r.outgoing,
        rateB: r.incoming,
        pitch: pitchCentsAt(prog, p),
        hpf: fx.hpfA,
        lpf: fx.lpfB,
        echo: fx.echoA,
        duck: fx.vocalDuckBDb,
      };
    }

    let aGain = env.volA;
    let leadGain = 0;
    if (t < leadPad) {
      aGain = 0;
      leadGain = 0;
    } else if (t < blendStart) {
      const fin = Math.min(1, (t - leadPad) / 0.01);
      leadGain = fin;
      aGain = bakedA ? 0 : fin;
    } else if (bakedA) {
      // Keep full-band dry A until B is loud enough to cover the carved vocal.
      if (t <= tBed0) {
        leadGain = 1;
        aGain = 0;
      } else if (t < tBed) {
        const u = (t - tBed0) / Math.max(1e-4, tBed - tBed0);
        const ease = u * u * (3 - 2 * u);
        leadGain = Math.cos(ease * Math.PI * 0.5);
        aGain = env.volA * Math.sin(ease * Math.PI * 0.5);
      } else {
        leadGain = 0;
        aGain = env.volA;
      }
    }

    if (t > total - 0.015) {
      const u = Math.min(1, (t - (total - 0.015)) / 0.015);
      aGain *= 1 - u;
      env.volB *= 1 - u;
      leadGain *= 1 - u;
    }

    volA.push({ t, v: aGain });
    volB.push({ t, v: t < blendStart ? 0 : env.volB });
    volLead.push({ t, v: leadGain });
    bassOut.push({ t, v: t < blendStart ? 0 : env.bassA });
    bassIn.push({ t, v: t < blendStart ? 0 : env.bassB });
    rateA.push({ t, v: env.rateA });
    rateB.push({ t, v: t < blendStart ? 1 : env.rateB });
    pitch.push({ t, v: t < blendStart ? 0 : env.pitch });
    hpfPts.push({ t, v: t < blendStart ? 20 : hpfHz(env.hpf, sr) });
    lpfPts.push({ t, v: lpfHz(t < blendStart ? 0 : env.lpf, sr) });
    duckPts.push({ t, v: t < blendStart ? 0 : env.duck });
    const e = t < blendStart ? 0 : env.echo;
    echoWet.push({ t, v: 0.7 * e });
    echoFb.push({ t, v: 0.25 + 0.35 * e });
    echoDry.push({ t, v: 1 - 0.15 * e });
  }

  scheduleParam(gainA.gain, volA);
  scheduleParam(gainB.gain, volB);
  if (srcLead._leadGain) scheduleParam(srcLead._leadGain.gain, volLead);
  scheduleParam(bassA.gain, bassOut);
  scheduleParam(bassB.gain, bassIn);
  scheduleParam(hpf.frequency, hpfPts);
  scheduleParam(lpf.frequency, lpfPts);
  if (bMid) scheduleParam(bMid.gain, duckPts);
  if (echo) {
    scheduleParam(echo.wet.gain, echoWet);
    scheduleParam(echo.fb.gain, echoFb);
    scheduleParam(echo.dry.gain, echoDry);
  }

  const rateNodeA = bakedA ? srcBlendA : srcLead;
  scheduleParam(rateNodeA.playbackRate, rateA);
  // Same rate as the bed so the short dry→carve fade stays sample-aligned.
  if (bakedA) scheduleParam(srcLead.playbackRate, rateA);
  scheduleParam(srcB.playbackRate, rateB);
  scheduleParam(srcB.detune, pitch);

  if (!bakedA) {
    srcLead.start(leadPad, Math.max(0, cueA - leadActual), Math.max(0.05, leadActual + blendDur));
  } else if (leadActual > 0.02) {
    const offset = Math.max(0, cueA - leadActual);
    const avail = Math.max(0.05, aFull.duration - offset - 0.02);
    const dryDur = Math.min(avail, leadActual + Math.max(bedFade, tBed - blendStart) + 0.06);
    srcLead.start(leadPad, offset, dryDur);
  }
  if (bakedA) srcBlendA.start(blendStart, aBlendOffset, blendDur + 0.05);
  srcB.start(blendStart, bOffset, blendDur + TAIL_SEC);

  const rendered = await ctx.startRendering();
  continuityRide(rendered, leadPad + 0.2, Math.max(leadPad + 0.5, blendStart - 0.08));
  const norm = peakNormalize(rendered, TARGET_LIN);
  const qa = {
    peakDb: 20 * Math.log10(peakOf(rendered) + 1e-12),
    peakBeforeDb: 20 * Math.log10(norm.peakBefore + 1e-12),
    leadRms: sectionRms(rendered, leadPad + 0.12, Math.max(leadPad + 0.4, blendStart - 0.05)),
    blendRms: sectionRms(rendered, blendStart + 0.4, blendEnd - 0.2),
    tailRms: sectionRms(rendered, blendEnd + 0.25, total - 0.2),
    channels: rendered.numberOfChannels,
    sampleRate: rendered.sampleRate,
    frames: rendered.length,
  };
  const db = (x) => 20 * Math.log10(x + 1e-12);
  const leadDb = db(qa.leadRms);
  const blendDb = db(qa.blendRms);
  const tailDb = db(qa.tailRms);
  qa.leadDb = leadDb;
  qa.blendDb = blendDb;
  qa.tailDb = tailDb;
  const inviteDb = db(sectionRms(rendered, blendStart, Math.min(total, blendStart + 4)));
  const mashDb = db(
    sectionRms(rendered, Math.min(total, blendStart + 4), Math.min(total, blendStart + 12))
  );
  const landDb = db(sectionRms(rendered, Math.min(total - 0.2, blendStart + 12), total - 0.15));
  qa.inviteDb = inviteDb;
  qa.mashDb = mashDb;
  qa.landDb = landDb;
  qa.truePeakDb = 20 * Math.log10((norm.truePeak || peakOf(rendered)) + 1e-12);
  const rise = maxRiseDb(rendered, 0.5, Math.max(0, blendStart - 0.5));
  qa.maxRiseDb = rise.db;
  qa.maxRiseAtSec = rise.at;
  let leadFloor = 1;
  for (let t = leadPad; t + 0.5 <= blendStart + 1e-4; t += 0.25) {
    leadFloor = Math.min(leadFloor, sectionRms(rendered, t, t + 0.5));
  }
  qa.leadFloorDb = db(leadFloor);
  let inviteFloor = 1;
  for (let t = blendStart; t + 0.5 <= Math.min(total, blendStart + 4); t += 0.25) {
    inviteFloor = Math.min(inviteFloor, sectionRms(rendered, t, t + 0.5));
  }
  qa.inviteFloorDb = db(inviteFloor);
  const nearLead = (x) => Math.abs(x - leadDb) <= 6.2;
  const levelRef = Math.min(leadDb, blendDb);
  qa.continuityOk =
    nearLead(inviteDb) &&
    nearLead(mashDb) &&
    nearLead(landDb) &&
    landDb <= leadDb + 6 &&
    rise.db <= 8 &&
    qa.leadFloorDb >= levelRef - 8 &&
    qa.inviteFloorDb >= levelRef - 8;
  qa.ok =
    rendered.numberOfChannels === 2 &&
    qa.truePeakDb <= -0.85 &&
    qa.truePeakDb >= -1.35 &&
    qa.peakDb >= -3.2 &&
    qa.leadRms > 1e-3 &&
    qa.blendRms > 1e-3 &&
    qa.tailRms > 1e-4 &&
    qa.continuityOk;

  return {
    buffer: rendered,
    cueA: hit.musical?.cueA ?? cueA,
    cueB: hit.musical?.cueB ?? cueB,
    blend: blendDur,
    leadIn: LEAD_SEC,
    leadActual,
    tail: tailSec,
    total,
    bakedA,
    qa,
    sampleRate: sr,
    resampledB: decodedB.sampleRate !== sr,
  };
}

function gateBrief(gates) {
  return (gates || []).map((g) => `${g.ok ? "ok" : "FAIL"} ${g.id}: ${g.detail}`);
}

async function main() {
  mkdirSync(outDir, { recursive: true });
  mkdirSync(optArtifacts, { recursive: true });

  const files = listCache();
  if (files.length < 2) {
    console.error("Need ≥2 tracks in .ym-cache");
    process.exit(1);
  }
  const pairs = pairCandidates(files);
  const coachRaw = loadCoach();
  console.log(
    `Pairs ${pairs.length} · files ${files.length} · coach ${coachRaw ? `n=${coachRaw.samples} avg=${coachRaw.avgScore}` : "off"}`
  );

  const ranked = [];
  for (let i = 0; i < pairs.length; i++) {
    const pair = pairs[i];
    try {
      process.stdout.write(
        `[${i + 1}/${pairs.length}] ${pair.kind} ${basename(pair.a)} × ${basename(pair.b)} … `
      );
      const hit = await scorePair(pair, coachRaw);
      console.log(
        `composite=${hit.composite} rank=${rankOf(hit).toFixed(0)} ` +
          `critic=${hit.critic.score}${hit.critic.ok ? "" : "!"} ` +
          `coach=${hit.coach.score}${hit.coach.ok ? "" : "!"} ${hit.mode} ` +
          `A@${hit.plan.params.cueASec.toFixed(1)}s B@${hit.plan.params.cueBSec.toFixed(1)}s`
      );
      ranked.push(hit);
    } catch (e) {
      console.log(`FAIL ${e instanceof Error ? e.message : e}`);
    }
  }
  ranked.sort((a, b) => {
    if (better(a, b)) return -1;
    if (better(b, a)) return 1;
    return 0;
  });
  if (!ranked.length) {
    console.error("No usable pair");
    process.exit(1);
  }

  console.log("\nTop scores:");
  for (const hit of ranked.slice(0, 8)) {
    console.log(
      `  ${hit.composite}  critic ${hit.critic.score} coach ${hit.coach.score}  ${hit.mode}  ` +
        `${basename(hit.a)} × ${basename(hit.b)}`
    );
  }

  let rendered = null;
  let winner = null;
  const attempts = ranked.slice(0, 12);
  for (const hit of attempts) {
    if (hit.composite < 85 || !hit.critic.ok || !hit.coach.ok) {
      console.log(
        `\nSkip ${basename(hit.a)} × ${basename(hit.b)} · ${hit.mode} · ${hit.composite} (want ≥85 and both gates)`
      );
      continue;
    }
    console.log(`\nRendering ${basename(hit.a)} × ${basename(hit.b)} · ${hit.mode} · ${hit.composite}`);
    try {
      const out = await renderMashup(hit);
      console.log(
        `  qa peak=${out.qa.peakDb.toFixed(2)} tp=${out.qa.truePeakDb.toFixed(2)} dB ` +
          `lead=${out.qa.leadDb.toFixed(1)} invite=${out.qa.inviteDb.toFixed(1)} ` +
          `mash=${out.qa.mashDb.toFixed(1)} land=${out.qa.landDb.toFixed(1)} ` +
          `rise=${out.qa.maxRiseDb.toFixed(1)}@${out.qa.maxRiseAtSec.toFixed(1)}s ` +
          `floor=${out.qa.leadFloorDb.toFixed(1)}/${out.qa.inviteFloorDb.toFixed(1)} ` +
          `cont=${out.qa.continuityOk} bakeA=${out.bakedA}`
      );
      if (!out.qa.ok) {
        console.log("  qa reject, trying next");
        continue;
      }
      rendered = out;
      winner = hit;
      break;
    } catch (e) {
      console.log(`  render FAIL ${e instanceof Error ? e.stack || e.message : e}`);
    }
  }
  if (!rendered || !winner) {
    console.error("No pair produced a good render");
    process.exit(1);
  }

  const wavPath = join(outDir, "sonivo-ideal-automix.wav");
  const mp3Path = join(outDir, "sonivo-ideal-automix.mp3");
  const jsonPath = join(outDir, "sonivo-ideal-automix.json");
  writeFileSync(wavPath, encodeWav(rendered.buffer));
  const ff = spawnSync(
    "ffmpeg",
    ["-y", "-hide_banner", "-loglevel", "error", "-i", wavPath, "-c:a", "libmp3lame", "-b:a", "320k", mp3Path],
    { encoding: "utf8" }
  );
  if (ff.status !== 0) {
    console.error(ff.stderr || ff.stdout);
    process.exit(1);
  }

  const preview = [0, 0.25, 0.5, 0.75, 1].map((prog) => {
    const v = volumesAt(prog, winner.plan.params);
    const b = bassGainDbAt(prog, winner.plan.params);
    const r = playbackRatesAt(prog, winner.plan.params);
    return {
      p: prog,
      volA: +v.outgoing.toFixed(3),
      volB: +v.incoming.toFixed(3),
      bassA: +b.outgoing.toFixed(2),
      bassB: +b.incoming.toFixed(2),
      rateA: +r.outgoing.toFixed(4),
      rateB: +r.incoming.toFixed(4),
      pitchB: +pitchCentsAt(prog, winner.plan.params).toFixed(1),
    };
  });

  const meta = {
    createdAt: new Date().toISOString(),
    pair: {
      a: basename(winner.a),
      b: basename(winner.b),
      kind: winner.kind,
      aPath: winner.a,
      bPath: winner.b,
    },
    mode: winner.mode,
    story: winner.plan.story,
    transitionType: winner.plan.transitionType,
    scores: {
      composite: winner.composite,
      formula: "round(0.5 * mixCritic + 0.5 * coach)",
      mixCritic: winner.critic.score,
      criticOk: winner.critic.ok,
      criticMode: winner.critic.mode,
      coach: winner.coach.score,
      coachOk: winner.coach.ok,
      coachStory: winner.coach.story,
      criticGates: gateBrief(winner.critic.gates),
      coachGates: gateBrief(winner.coach.gates),
    },
    cues: {
      cueASec: rendered.cueA,
      cueBSec: rendered.cueB,
      plannedCueASec: winner.plan.params.cueASec,
      plannedCueBSec: winner.plan.params.cueBSec,
      mixOutASec: winner.profileA.mixOutSec,
      mixInBSec: winner.profileB.mixInSec,
      blendSec: rendered.blend,
      leadInSec: rendered.leadIn,
      tailAfterBlendSec: rendered.tail,
      handoffAt: winner.plan.params.handoffAt,
      bassSwapAt: winner.plan.params.bassSwapAt,
      totalSec: rendered.total,
      neuralA: winner.profileA.reason,
      neuralB: winner.profileB.reason,
    },
    bpm: {
      a: winner.profileA.bpm,
      b: winner.profileB.bpm,
      target: winner.plan.params.targetBPM,
      rateA: winner.musical?.rateA ?? winner.plan.params.rateA,
      rateB: winner.musical?.rateB ?? winner.plan.params.rateB,
      pitchSafe: Boolean(winner.musical?.pitchSafe),
    },
    keys: {
      a: winner.profileA.camelotKey,
      b: winner.profileB.camelotKey,
      pitchCentsB: winner.plan.params.pitchCentsB,
    },
    bakeInstrA: rendered.bakedA,
    sampleRate: rendered.sampleRate,
    channels: rendered.buffer.numberOfChannels,
    resampledB: rendered.resampledB,
    qa: rendered.qa,
    envelopePreview: preview,
    files: { wav: wavPath, mp3: mp3Path, json: jsonPath },
    note: "WAV is PCM16 peak-normalized to -1.0 dBFS. MP3 is 320 kbps CBR. Tempo lock is rubberband (pitch preserved) when the beatmatch rate is not 1.",
  };
  writeFileSync(jsonPath, JSON.stringify(meta, null, 2));

  for (const src of [mp3Path, jsonPath]) {
    copyFileSync(src, join(optArtifacts, basename(src)));
  }
  copyFileSync(wavPath, join(optArtifacts, basename(wavPath)));

  console.log("\nDONE");
  console.log(JSON.stringify(meta.scores, null, 2));
  console.log(wavPath);
  console.log(mp3Path);
  console.log(jsonPath);
}

try {
  await main();
} catch (e) {
  console.error(e);
  process.exitCode = 1;
} finally {
  try {
    rmSync(bundled.dir, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
}
