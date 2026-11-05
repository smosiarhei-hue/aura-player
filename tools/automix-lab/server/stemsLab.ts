/**
 * Background HTDemucs windows for AutoMix transitions.
 *
 * Yandex returns a mixed file. While that file plays, this plugin splits the
 * outro (A) or intro (B) with demucs-onnx. Playback never waits on it.
 * Repo: https://github.com/StemSplit/demucs-onnx
 */
import type { Plugin, Connect } from "vite";
import { spawn } from "node:child_process";
import { createReadStream, existsSync, mkdirSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const labRoot = join(root, "..");
const cacheDir = join(labRoot, ".ym-cache");
const stemRoot = join(labRoot, ".stem-cache");
const script = join(labRoot, "scripts", "separate-window.py");

type StemJob = {
  trackId: string;
  role: "outro" | "intro";
  phase: "queued" | "running" | "ready" | "error";
  error?: string;
  startSec: number;
  durationSec: number;
  vocalsUrl?: string;
  instrumentalUrl?: string;
};

const jobs = new Map<string, StemJob>();
const queue: string[] = [];
let active = false;

function json(res: Connect.ServerResponse, status: number, body: unknown) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(JSON.stringify(body));
}

async function readBody(req: Connect.IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(Buffer.from(c));
  return Buffer.concat(chunks).toString("utf8");
}

function safeFile(name: string): string | null {
  const base = basename(name);
  if (!base || base !== name || base.includes("..")) return null;
  const path = join(cacheDir, base);
  if (!existsSync(path)) return null;
  return path;
}

function jobKey(trackId: string, role: string, startSec = 0) {
  return `${role}:${trackId}:${Math.round(startSec)}`;
}

function pump() {
  if (active) return;
  const key = queue.shift();
  if (!key) return;
  const job = jobs.get(key);
  if (!job || job.phase === "ready") {
    pump();
    return;
  }
  active = true;
  job.phase = "running";
  const out = join(stemRoot, job.role, job.trackId, String(Math.round(job.startSec)));
  mkdirSync(out, { recursive: true });
  const input = jobInput.get(key);
  if (!input) {
    job.phase = "error";
    job.error = "missing file";
    active = false;
    pump();
    return;
  }
  const child = spawn(
    process.env.STEM_PYTHON || "python3",
    [
      script,
      "--input",
      input,
      "--start",
      String(job.startSec),
      "--duration",
      String(job.durationSec),
      "--out",
      out,
      "--track-id",
      job.trackId,
    ],
    { cwd: labRoot }
  );
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (buf) => {
    stdout += String(buf);
  });
  child.stderr.on("data", (buf) => {
    stderr += String(buf);
  });
  child.on("close", (code) => {
    const line = stdout.trim().split("\n").filter(Boolean).pop() || "";
    let parsed: { ok?: boolean; error?: string } = {};
    try {
      parsed = JSON.parse(line);
    } catch {
      parsed = { ok: false, error: (stderr || line || `exit ${code}`).slice(-500) };
    }
    if (code === 0 && parsed.ok) {
      job.phase = "ready";
      const stamp = Math.round(job.startSec);
      job.vocalsUrl = `/api/stems/file/${job.role}/${job.trackId}/${stamp}/vocals.wav`;
      job.instrumentalUrl = `/api/stems/file/${job.role}/${job.trackId}/${stamp}/instrumental.wav`;
    } else {
      job.phase = "error";
      job.error = parsed.error || `exit ${code}`;
    }
    active = false;
    pump();
  });
}

const jobInput = new Map<string, string>();

export function stemsLabPlugin(): Plugin {
  return {
    name: "automix-lab-stems",
    configureServer(server) {
      if (!existsSync(stemRoot)) mkdirSync(stemRoot, { recursive: true });
      server.middlewares.use(async (req, res, next) => {
        const url = req.url || "";
        if (!url.startsWith("/api/stems/")) return next();
        try {
          if (url.startsWith("/api/stems/status") && req.method === "GET") {
            const query = new URL(url, "http://lab").searchParams;
            const id = query.get("trackId") || "";
            const role = query.get("role") || "outro";
            const start = Number(query.get("start") || "0");
            const job = jobs.get(jobKey(id, role, start));
            if (!job) return json(res, 404, { phase: "idle" });
            return json(res, 200, job);
          }

          if (url.startsWith("/api/stems/file/") && req.method === "GET") {
            const rel = decodeURIComponent(url.slice("/api/stems/file/".length).split("?")[0]!);
            const parts = rel.split("/").filter(Boolean);
            if (parts.length !== 4) return json(res, 400, { error: "bad path" });
            const [role, trackId, start, name] = parts;
            if (
              (role !== "outro" && role !== "intro") ||
              (name !== "vocals.wav" && name !== "instrumental.wav" && name !== "meta.json") ||
              !/^[\w.:-]+$/.test(trackId) ||
              !/^\d+$/.test(start || "")
            ) {
              return json(res, 400, { error: "bad path" });
            }
            const path = join(stemRoot, role, trackId, start, name);
            if (!existsSync(path)) return json(res, 404, { error: "not ready" });
            res.statusCode = 200;
            res.setHeader(
              "Content-Type",
              name.endsWith(".json") ? "application/json" : "audio/wav"
            );
            createReadStream(path).pipe(res);
            return;
          }

          if (url === "/api/stems/window" && req.method === "POST") {
            const body = JSON.parse((await readBody(req)) || "{}") as {
              file?: string;
              trackId?: string;
              startSec?: number;
              durationSec?: number;
              role?: "outro" | "intro";
            };
            if (!body.file || !body.trackId) {
              return json(res, 400, { error: "file and trackId required" });
            }
            const input = safeFile(body.file);
            if (!input) return json(res, 404, { error: "cache file missing" });
            const role = body.role === "intro" ? "intro" : "outro";
            const startSec = Math.max(0, Number(body.startSec) || 0);
            const key = jobKey(body.trackId, role, startSec);
            const existing = jobs.get(key);
            if (existing && (existing.phase === "ready" || existing.phase === "running" || existing.phase === "queued")) {
              return json(res, 200, existing);
            }
            const job: StemJob = {
              trackId: body.trackId,
              role,
              phase: "queued",
              startSec,
              durationSec: Math.min(40, Math.max(8, Number(body.durationSec) || 36)),
            };
            jobs.set(key, job);
            jobInput.set(key, input);
            queue.push(key);
            pump();
            return json(res, 200, job);
          }

          return json(res, 404, { error: "unknown stems route" });
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          return json(res, 500, { error: msg });
        }
      });
    },
  };
}
