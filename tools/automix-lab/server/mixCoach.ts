/**
 * Vite middleware: transition coach log + learned offsets.
 * Persists `.mix-coach.json` and `.mix-log.jsonl` (gitignored).
 */
import type { Plugin, Connect } from "vite";
import { readFileSync, writeFileSync, existsSync, appendFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const labRoot = join(root, "..");
const coachPath = join(labRoot, ".mix-coach.json");
const logPath = join(labRoot, ".mix-log.jsonl");

type CoachOffsets = {
  earlierCarve: number;
  laterVocalOpen: number;
  earlierBass: number;
  deeperBass: number;
  quieterDualA: number;
  landHpf: number;
  echoCap: number;
  cueShiftSec: number;
  samples: number;
  avgScore: number;
  updatedAt: string;
};

const DEFAULT: CoachOffsets = {
  earlierCarve: 0,
  laterVocalOpen: 0,
  earlierBass: 0,
  deeperBass: 0,
  quieterDualA: 0,
  landHpf: 0,
  echoCap: 0,
  cueShiftSec: 0,
  samples: 0,
  avgScore: 100,
  updatedAt: new Date(0).toISOString(),
};

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

function readCoach(): CoachOffsets {
  try {
    if (!existsSync(coachPath)) return { ...DEFAULT };
    const raw = readFileSync(coachPath, "utf8").trim();
    if (!raw) return { ...DEFAULT };
    return { ...DEFAULT, ...JSON.parse(raw) };
  } catch {
    return { ...DEFAULT };
  }
}

function writeCoach(c: CoachOffsets) {
  writeFileSync(coachPath, JSON.stringify(c, null, 2), "utf8");
}

function clamp(v: number, lo: number, hi: number) {
  return Math.min(hi, Math.max(lo, v));
}

function learn(prev: CoachOffsets, report: {
  ok: boolean;
  score: number;
  gates?: { ok: boolean; nudge?: { key: string; delta: number } }[];
}): CoachOffsets {
  const next: CoachOffsets = {
    ...prev,
    samples: prev.samples + 1,
    avgScore:
      prev.samples <= 0
        ? report.score
        : Math.round((prev.avgScore * prev.samples + report.score) / (prev.samples + 1)),
    updatedAt: new Date().toISOString(),
  };
  if (report.ok || !report.gates) return next;

  const caps: Record<string, { lo: number; hi: number }> = {
    earlierCarve: { lo: 0, hi: 0.18 },
    laterVocalOpen: { lo: 0, hi: 0.25 },
    earlierBass: { lo: 0, hi: 0.2 },
    deeperBass: { lo: 0, hi: 0.35 },
    quieterDualA: { lo: 0, hi: 0.28 },
    landHpf: { lo: 0, hi: 0.4 },
    echoCap: { lo: 0, hi: 0.45 },
    cueShiftSec: { lo: -8, hi: 4 },
  };

  for (const g of report.gates) {
    if (g.ok || !g.nudge) continue;
    const key = g.nudge.key as keyof CoachOffsets;
    const range = caps[key as string];
    if (!range) continue;
    const cur = Number(next[key]) || 0;
    (next as unknown as Record<string, number>)[key] = clamp(
      cur + g.nudge.delta,
      range.lo,
      range.hi
    );
  }
  return next;
}

export function mixCoachPlugin(): Plugin {
  return {
    name: "automix-lab-coach",
    configureServer(server) {
      if (!existsSync(join(labRoot, ".ym-cache"))) {
        mkdirSync(join(labRoot, ".ym-cache"), { recursive: true });
      }

      server.middlewares.use(async (req, res, next) => {
        const url = req.url || "";
        if (!url.startsWith("/api/mix/")) return next();

        try {
          if (url === "/api/mix/coach" && req.method === "GET") {
            return json(res, 200, readCoach());
          }

          if (url === "/api/mix/coach" && req.method === "PUT") {
            const body = JSON.parse((await readBody(req)) || "{}") as Partial<CoachOffsets>;
            const merged = { ...readCoach(), ...body, updatedAt: new Date().toISOString() };
            writeCoach(merged);
            return json(res, 200, merged);
          }

          if (url === "/api/mix/coach/reset" && req.method === "POST") {
            writeCoach({ ...DEFAULT, updatedAt: new Date().toISOString() });
            return json(res, 200, readCoach());
          }

          if (url === "/api/mix/log" && req.method === "POST") {
            const raw = await readBody(req);
            const entry = JSON.parse(raw || "{}") as {
              report?: {
                ok: boolean;
                score: number;
                gates?: { ok: boolean; nudge?: { key: string; delta: number } }[];
                story?: string;
                mode?: string;
                tweaks?: string[];
              };
              pair?: { a?: string; b?: string };
              learn?: boolean;
              at?: string;
            };
            const line = JSON.stringify({
              at: entry.at || new Date().toISOString(),
              pair: entry.pair || null,
              report: entry.report || null,
            });
            appendFileSync(logPath, line + "\n", "utf8");

            let coach = readCoach();
            if (entry.learn !== false && entry.report) {
              coach = learn(coach, entry.report);
              writeCoach(coach);
            }
            return json(res, 200, {
              ok: true,
              coach,
              learned: entry.learn !== false && Boolean(entry.report) && !entry.report.ok,
            });
          }

          if (url.startsWith("/api/mix/log") && req.method === "GET") {
            const limit = Math.min(
              50,
              Math.max(1, Number(new URL(url, "http://x").searchParams.get("limit") || 12))
            );
            if (!existsSync(logPath)) return json(res, 200, { entries: [], coach: readCoach() });
            const lines = readFileSync(logPath, "utf8")
              .trim()
              .split("\n")
              .filter(Boolean);
            const entries = lines
              .slice(-limit)
              .map((l) => {
                try {
                  return JSON.parse(l);
                } catch {
                  return null;
                }
              })
              .filter(Boolean)
              .reverse();
            return json(res, 200, { entries, coach: readCoach() });
          }

          return json(res, 404, { error: "unknown mix route" });
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          return json(res, 500, { error: msg });
        }
      });
    },
  };
}
