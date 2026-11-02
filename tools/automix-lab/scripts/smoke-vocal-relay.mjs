/**
 * Headless Vocal Relay proof via Playwright against a running Lab server.
 * Usage: LAB_URL=http://127.0.0.1:43187 node scripts/smoke-vocal-relay.mjs
 */
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

// Lab DSP debug surface lives on /lab.html (player `/` has no __automixLab).
const raw = process.env.LAB_URL || "http://127.0.0.1:43187/lab.html";
const url = /lab\.html(?:\?|$)/.test(raw)
  ? raw
  : raw.replace(/\/?$/, "/lab.html");
const require = createRequire(import.meta.url);

async function ensurePlaywright() {
  try {
    return require("playwright");
  } catch {
    console.log("Installing playwright + chromium…");
    const r = spawnSync(
      "npm",
      ["install", "--no-save", "playwright@1.55.0"],
      { stdio: "inherit", cwd: new URL("..", import.meta.url).pathname }
    );
    if (r.status !== 0) process.exit(1);
    const r2 = spawnSync("npx", ["playwright", "install", "chromium"], {
      stdio: "inherit",
      cwd: new URL("..", import.meta.url).pathname,
    });
    if (r2.status !== 0) process.exit(1);
    return require("playwright");
  }
}

const { chromium } = await ensurePlaywright();
const browser = await chromium.launch({
  headless: true,
  args: ["--autoplay-policy=no-user-gesture-required", "--use-fake-device-for-media-stream"],
});
const page = await browser.newPage();
page.setDefaultTimeout(120_000);

console.log(`Open ${url}`);
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForFunction(() => !!window.__automixLab);

console.log("Load demo + Auto Mix…");
await page.evaluate(async () => {
  await window.__automixLab.loadDemo();
  await window.__automixLab.autoMix();
});

// Full blend ~16s — wait until settled B vocal window + buffer for trail.
await page.waitForTimeout(14_000);

const plan = await page.evaluate(() => window.__automixLab.getPlan());
const proof = await page.evaluate(() => window.__automixLab.relayProof());
const trailN = await page.evaluate(() => window.__automixLab.getTrail().length);

console.log("plan:", JSON.stringify(plan, null, 2));
console.log("proof:", JSON.stringify(proof, null, 2));
console.log("trail samples:", trailN);

await page.evaluate(() => window.__automixLab.stop());
await browser.close();

if (!proof.ok) {
  console.error("\nVocal Relay smoke FAILED:", proof.detail);
  process.exit(1);
}
console.log("\nVocal Relay smoke PASSED:", proof.detail);
