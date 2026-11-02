/**
 * Offline Whisper (transformers.js) + optional Yandex LRC for Automix cues.
 * First run downloads the tiny multilingual model into `.whisper-cache/`.
 */
import type { Plugin, Connect } from "vite";
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const labRoot = join(root, "..");
const cacheDir = join(labRoot, ".ym-cache");
const transcriptDir = join(labRoot, ".whisper-cache", "transcripts");
const modelCacheDir = join(labRoot, ".whisper-cache", "models");

type Word = { text: string; start: number; end: number };
type Segment = { text: string; start: number; end: number; words?: Word[] };
type Transcript = {
  language: string | null;
  source: "whisper" | "yandex-lrc" | "none";
  segments: Segment[];
  text: string;
  trackId?: string;
};

let asrPromise: Promise<((audio: Float32Array) => Promise<unknown>) | null> | null =
  null;

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

function ensureDirs() {
  for (const d of [transcriptDir, modelCacheDir]) {
    if (!existsSync(d)) mkdirSync(d, { recursive: true });
  }
}

function transcriptPath(trackId: string) {
  return join(transcriptDir, `${trackId}.json`);
}

function readCached(trackId: string): Transcript | null {
  const p = transcriptPath(trackId);
  if (!existsSync(p)) return null;
  try {
    return JSON.parse(readFileSync(p, "utf8")) as Transcript;
  } catch {
    return null;
  }
}

function writeCached(trackId: string, t: Transcript) {
  writeFileSync(transcriptPath(trackId), JSON.stringify(t, null, 2), "utf8");
}

function downsampleMono(
  channelData: Float32Array[],
  sampleRate: number,
  targetRate = 16000
): Float32Array {
  const ch = channelData.length;
  const len = channelData[0]?.length || 0;
  const mono = new Float32Array(len);
  for (let i = 0; i < len; i++) {
    let s = 0;
    for (let c = 0; c < ch; c++) s += channelData[c]![i] || 0;
    mono[i] = s / Math.max(1, ch);
  }
  if (sampleRate === targetRate) return mono;
  const ratio = sampleRate / targetRate;
  const n = Math.floor(mono.length / ratio);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = mono[Math.floor(i * ratio)] || 0;
  }
  return out;
}

async function loadAsr() {
  if (!asrPromise) {
    asrPromise = (async () => {
      try {
        process.env.TRANSFORMERS_CACHE = modelCacheDir;
        process.env.HF_HOME = modelCacheDir;
        const mod = await import("@huggingface/transformers");
        const { pipeline, env } = mod as {
          pipeline: (
            task: string,
            model: string,
            opts?: Record<string, unknown>
          ) => Promise<(audio: Float32Array | string, opts?: Record<string, unknown>) => Promise<unknown>>;
          env: { cacheDir: string; allowLocalModels: boolean; useBrowserCache: boolean };
        };
        env.cacheDir = modelCacheDir;
        env.allowLocalModels = true;
        // tiny multilingual — RU/EN tracks on Моя волна
        const pipe = await pipeline(
          "automatic-speech-recognition",
          "Xenova/whisper-tiny",
          { dtype: "fp32" }
        );
        return async (audio: Float32Array) =>
          pipe(audio, {
            language: null,
            task: "transcribe",
            return_timestamps: "word",
            chunk_length_s: 30,
            stride_length_s: 5,
          });
      } catch (e) {
        console.error("[whisper] failed to load", e);
        return null;
      }
    })();
  }
  return asrPromise;
}

function emptyTranscript(): Transcript {
  return { language: null, source: "none", segments: [], text: "" };
}

function shiftTranscript(t: Transcript, offsetSec: number): Transcript {
  if (!(offsetSec > 0) || !t.segments.length) return t;
  return {
    ...t,
    segments: t.segments.map((s) => ({
      ...s,
      start: s.start + offsetSec,
      end: s.end + offsetSec,
      words: s.words?.map((w) => ({
        ...w,
        start: w.start + offsetSec,
        end: w.end + offsetSec,
      })),
    })),
  };
}

function mergeTranscripts(a: Transcript, b: Transcript): Transcript {
  const segments = [...a.segments, ...b.segments].sort((x, y) => x.start - y.start);
  const hasWords = segments.some((s) => (s.words?.length || 0) > 0 || s.text.trim());
  return {
    language: a.language || b.language,
    source: hasWords ? "whisper" : "none",
    segments,
    text: segments
      .map((s) => s.text)
      .filter(Boolean)
      .join(" ")
      .trim(),
  };
}

function normalizeWhisperResult(raw: unknown): Transcript {
  const r = raw as {
    text?: string;
    chunks?: { text?: string; timestamp?: [number, number] | number[] }[];
  };
  const segments: Segment[] = [];
  const words: Word[] = [];
  for (const c of r.chunks || []) {
    const ts = c.timestamp;
    const start = Array.isArray(ts) ? Number(ts[0] ?? 0) : 0;
    const end = Array.isArray(ts) ? Number(ts[1] ?? start) : start;
    const text = String(c.text || "").trim();
    if (!text) continue;
    words.push({ text, start, end: Math.max(end, start + 0.05) });
  }
  // Group words into ~phrase segments (gap > 0.6s).
  let buf: Word[] = [];
  const flush = () => {
    if (!buf.length) return;
    segments.push({
      text: buf.map((w) => w.text).join(" ").replace(/\s+/g, " ").trim(),
      start: buf[0]!.start,
      end: buf[buf.length - 1]!.end,
      words: buf.slice(),
    });
    buf = [];
  };
  for (const w of words) {
    if (buf.length && w.start - buf[buf.length - 1]!.end > 0.65) flush();
    buf.push(w);
  }
  flush();

  return {
    language: null,
    source: words.length ? "whisper" : "none",
    segments,
    text: (r.text || segments.map((s) => s.text).join(" ")).trim(),
  };
}

function wordsFromLine(text: string, start: number, end: number): Word[] {
  const parts = text.split(/\s+/).filter(Boolean);
  if (!parts.length) return [];
  if (parts.length === 1) {
    return [{ text: parts[0]!, start, end: Math.max(end, start + 0.2) }];
  }
  const dur = Math.max(0.45, end - start);
  return parts.map((w, i) => {
    const s = start + (dur * i) / parts.length;
    const e = start + (dur * (i + 1)) / parts.length;
    return { text: w, start: s, end: Math.max(e, s + 0.08) };
  });
}

function parseLrc(lrc: string): Transcript {
  const lineRe = /\[(\d+):(\d+(?:\.\d+)?)\](.*)/g;
  const segments: Segment[] = [];
  let m: RegExpExecArray | null;
  const rows: { t: number; text: string }[] = [];
  while ((m = lineRe.exec(lrc))) {
    const min = Number(m[1]);
    const sec = Number(m[2]);
    const text = String(m[3] || "").trim();
    if (!text) continue;
    rows.push({ t: min * 60 + sec, text });
  }
  for (let i = 0; i < rows.length; i++) {
    const cur = rows[i]!;
    const next = rows[i + 1];
    const end = next ? Math.max(next.t, cur.t + 0.35) : cur.t + 3.2;
    const words = wordsFromLine(cur.text, cur.t, end);
    segments.push({
      text: cur.text,
      start: cur.t,
      end,
      words,
    });
  }
  return {
    language: null,
    source: segments.length ? "yandex-lrc" : "none",
    segments,
    text: segments.map((s) => s.text).join(" "),
  };
}

async function decodeFileToMono16k(filePath: string): Promise<Float32Array> {
  const decode = (await import("audio-decode")).default;
  const buf = readFileSync(filePath);
  const decoded = await decode(buf);
  return downsampleMono(decoded.channelData as Float32Array[], decoded.sampleRate, 16000);
}

function findCacheFileSafe(trackId: string): string | null {
  if (!existsSync(cacheDir)) return null;
  const files = readdirSync(cacheDir);
  const hit = files.find((f) => f.includes(trackId));
  return hit ? join(cacheDir, hit) : null;
}

export function whisperLabPlugin(): Plugin {
  return {
    name: "automix-lab-whisper",
    configureServer(server) {
      ensureDirs();

      server.middlewares.use(async (req, res, next) => {
        const url = req.url || "";
        if (!url.startsWith("/api/whisper/")) return next();

        try {
          if (url.startsWith("/api/whisper/transcript/") && req.method === "GET") {
            const trackId = decodeURIComponent(
              url.slice("/api/whisper/transcript/".length).split("?")[0]!
            );
            const cached = readCached(trackId);
            if (cached) return json(res, 200, cached);
            return json(res, 404, { error: "no transcript yet" });
          }

          if (url === "/api/whisper/transcribe" && req.method === "POST") {
            const raw = await readBody(req);
            const body = JSON.parse(raw || "{}") as {
              trackId?: string;
              fileName?: string;
              force?: boolean;
              lrc?: string;
            };
            if (!body.trackId) return json(res, 400, { error: "trackId required" });

            // Prefer fresh Yandex LRC whenever the client has it — karaoke sync
            // beats a stale Whisper/line-only cache.
            if (body.lrc && body.lrc.includes("[")) {
              const t = parseLrc(body.lrc);
              t.trackId = body.trackId;
              if (t.segments.length) {
                writeCached(body.trackId, t);
                return json(res, 200, t);
              }
            }

            if (!body.force) {
              const cached = readCached(body.trackId);
              if (cached && cached.source !== "none") {
                return json(res, 200, cached);
              }
            }

            const file =
              (body.fileName && join(cacheDir, body.fileName)) ||
              findCacheFileSafe(body.trackId);
            if (!file || !existsSync(file)) {
              return json(res, 404, { error: "audio cache missing — play/load track first" });
            }

            const asr = await loadAsr();
            if (!asr) {
              return json(res, 503, {
                error: "Whisper model unavailable",
                hint: "Check network once to download Xenova/whisper-tiny into .whisper-cache",
              });
            }

            const audio = await decodeFileToMono16k(file);
            // Automix only needs intro (mixIn) + outro (mixOut). Slice those
            // windows so Whisper returns in seconds, not minutes.
            const sr = 16000;
            const dur = audio.length / sr;
            const introSec = Math.min(48, Math.max(16, dur * 0.28));
            const outroSec = Math.min(72, Math.max(32, dur * 0.42));
            const outroStartSec = Math.max(0, dur - outroSec);
            const intro = audio.subarray(0, Math.min(audio.length, Math.floor(introSec * sr)));
            const outroOffset = Math.floor(outroStartSec * sr);
            const outro = audio.subarray(outroOffset);

            const [introRaw, outroRaw] = await Promise.all([
              asr(intro),
              outroStartSec > introSec + 4 ? asr(outro) : Promise.resolve(null),
            ]);
            const introTx = normalizeWhisperResult(introRaw);
            const outroTx = outroRaw
              ? shiftTranscript(normalizeWhisperResult(outroRaw), outroStartSec)
              : emptyTranscript();
            const transcript = mergeTranscripts(introTx, outroTx);
            transcript.trackId = body.trackId;
            writeCached(body.trackId, transcript);
            return json(res, 200, transcript);
          }

          if (url === "/api/whisper/status" && req.method === "GET") {
            return json(res, 200, {
              model: "Xenova/whisper-tiny",
              cache: modelCacheDir,
              offlineAfterWarmup: true,
            });
          }

          return json(res, 404, { error: "unknown whisper route" });
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          return json(res, 500, { error: msg });
        }
      });
    },
  };
}
