/**
 * Vite middleware: Yandex Music device auth + «Моя волна» for Automix Lab.
 *
 * Protocol: @dvxch/yandex-music (MarshalX-compatible Device Flow + rotor).
 * Token lives in `.ym-token.json` (gitignored) — never committed.
 *
 * Lossless (FLAC) requires the API to *grant* quality=lossless. From a US/EU
 * datacenter IP Yandex soft-downgrades every `/get-file-info` request to
 * nq/aac~192 even for Plus accounts in region 225 — set `YM_PROXY` (HTTP(S)
 * proxy in RU/BY) or run the lab from a CIS IP to unlock FLAC.
 */
import type { Plugin, Connect } from "vite";
import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Client, Request } from "@dvxch/yandex-music";
import { ProxyAgent, fetch as undiciFetch } from "undici";

const root = dirname(fileURLToPath(import.meta.url));
const labRoot = join(root, "..");
const tokenPath = join(labRoot, ".ym-token.json");
const cacheDir = join(labRoot, ".ym-cache");

/** What the Play button is waiting on — polled by the player. */
const loadPhase = {
  phase: "idle" as "idle" | "wave" | "file" | "decode" | "ready",
  label: "",
  startedAt: 0,
};

function setLoad(phase: typeof loadPhase.phase, label: string) {
  loadPhase.phase = phase;
  loadPhase.label = label;
  if (phase !== "idle" && loadPhase.startedAt === 0) loadPhase.startedAt = Date.now();
  if (phase === "idle" || phase === "ready") loadPhase.startedAt = 0;
}

type StoredToken = {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: number;
  login?: string;
};

type PendingAuth = {
  deviceCode: string;
  userCode: string;
  verificationUrl: string;
  intervalMs: number;
  expiresAt: number;
};

/** Last `/get-file-info` outcome — surfaced on /api/ym/status for the UI. */
type LosslessProbe = {
  trackId: string;
  requested: string;
  grantedQuality: string | null;
  codec: string | null;
  bitrateKbps: number | null;
  isLossless: boolean;
  used: "flac" | "lossy-fallback" | "error" | "null";
  detail: string;
  at: number;
};

let pending: PendingAuth | null = null;
let waveQueue: { id: string; title: string; artists: string; durationMs: number }[] = [];
let waveBatchId: string | undefined;
let waveCursor = 0;
let lastLosslessProbe: LosslessProbe | null = null;

function ymProxyUrl(): string | undefined {
  const raw =
    process.env.YM_PROXY?.trim() ||
    process.env.HTTPS_PROXY?.trim() ||
    process.env.HTTP_PROXY?.trim();
  return raw || undefined;
}

function buildClient(token?: string): Client {
  const proxy = ymProxyUrl();
  if (!proxy) {
    return new Client(token ? { token } : {});
  }
  const agent = new ProxyAgent(proxy);
  const request = new Request({
    timeout: 30_000,
    fetch: (url, init) =>
      undiciFetch(url, {
        method: init.method,
        headers: init.headers,
        body: init.body,
        signal: init.signal,
        dispatcher: agent,
      }) as unknown as Promise<Response>,
  });
  return new Client(token ? { token, request } : { request });
}

function readToken(): StoredToken | null {
  try {
    if (!existsSync(tokenPath)) return null;
    const raw = readFileSync(tokenPath, "utf8").trim();
    if (!raw) return null;
    const t = JSON.parse(raw) as StoredToken;
    if (!t?.accessToken) return null;
    return t;
  } catch {
    return null;
  }
}

function writeToken(t: StoredToken) {
  writeFileSync(tokenPath, JSON.stringify(t, null, 2), "utf8");
}

function clearToken() {
  try {
    if (existsSync(tokenPath)) unlinkSync(tokenPath);
  } catch {
    /* ignore */
  }
}

async function clientFromToken(): Promise<Client | null> {
  const t = readToken();
  if (!t?.accessToken) return null;
  const client = await buildClient(t.accessToken).init();
  return client;
}

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

async function ensureWaveBatch(client: Client) {
  const batch = await client.rotorStationTracks("user:onyourwave", false, waveBatchId);
  if (!batch?.sequence?.length) throw new Error("Моя волна пуста — попробуй ещё раз");
  waveBatchId = batch.batchId || waveBatchId;
  const items = batch.sequence
    .map((s) => {
      const tr = s.track;
      if (!tr?.id) return null;
      return {
        id: String(tr.id),
        title: tr.title || "Без названия",
        artists: (tr.artists || []).map((a) => a.name || "?").join(", ") || "—",
        durationMs: tr.durationMs || 0,
      };
    })
    .filter(Boolean) as typeof waveQueue;
  if (!items.length) throw new Error("В пакете волны нет треков");
  waveQueue = items;
  waveCursor = 0;
  try {
    await client.rotorStationFeedbackRadioStarted(
      "user:onyourwave",
      "automix-lab-wave",
      waveBatchId
    );
  } catch {
    /* feedback best-effort */
  }
}

function coverUrlFromTrack(track: {
  coverUri?: string;
  ogImage?: string;
}): string | null {
  const raw = track.coverUri || track.ogImage;
  if (!raw) return null;
  const sized = raw.replace("%%", "400x400");
  if (sized.startsWith("http")) return sized;
  return `https://${sized}`;
}

async function downloadTrackBytes(client: Client, trackId: string): Promise<{
  bytes: Uint8Array;
  meta: {
    id: string;
    title: string;
    artists: string;
    durationMs: number;
    coverUrl: string | null;
    codec: string;
    bitrateKbps: number;
    quality: "lossless" | "hq" | "nq";
    qualityNote?: string;
  };
}> {
  const tracks = await client.tracks(trackId);
  const track = tracks[0];
  if (!track) throw new Error(`Трек ${trackId} не найден`);

  const baseMeta = {
    id: String(track.id),
    title: track.title || "Без названия",
    artists: (track.artists || []).map((a) => a.name || "?").join(", ") || "—",
    durationMs: track.durationMs || 0,
    coverUrl: coverUrlFromTrack(track),
  };

  let qualityNote: string | undefined;

  const cached = readCachedTrack(trackId);
  if (cached) {
    setLoad("ready", `Из кэша · ${baseMeta.artists} — ${baseMeta.title}`);
    return cached;
  }

  setLoad("file", `Качаю · ${baseMeta.artists} — ${baseMeta.title}`);

  // Don't block Play on a slow lossless probe (often a geo downgrade).
  // If FLAC metadata returns quickly, use it; otherwise start the best lossy file.
  const LOSSLESS_BUDGET_MS = 800;
  const variantsP = track.getDownloadInfo();
  const flacMetaP = Promise.race([
    track
      .getLosslessInfo("lossless")
      .then((info) => info)
      .catch(() => null),
    new Promise<null>((resolve) => setTimeout(() => resolve(null), LOSSLESS_BUDGET_MS)),
  ]);

  try {
    const lossless = await flacMetaP;
    if (lossless?.isLossless) {
      setLoad("file", `Качаю FLAC · ${baseMeta.title}`);
      const bytes = await lossless.downloadBytes();
      if (bytes.byteLength > 1024) {
        lastLosslessProbe = {
          trackId,
          requested: "lossless",
          grantedQuality: String(lossless.quality || ""),
          codec: String(lossless.codec || ""),
          bitrateKbps: Number(lossless.bitrate || 0),
          isLossless: true,
          used: "flac",
          detail: "FLAC ok",
          at: Date.now(),
        };
        setLoad("ready", `Готово · ${baseMeta.title}`);
        return {
          bytes,
          meta: {
            ...baseMeta,
            codec: String(lossless.codec || "flac"),
            bitrateKbps: Number(lossless.bitrate || 0),
            quality: "lossless" as const,
          },
        };
      }
    }
  } catch {
    /* fall through to lossy */
  }

  qualityNote =
    "Старт без ожидания FLAC: лучший доступный поток. Lossless подхватится, если API ответит за 0.8 с.";
  lastLosslessProbe = {
    trackId,
    requested: "lossless",
    grantedQuality: null,
    codec: null,
    bitrateKbps: null,
    isLossless: false,
    used: "lossy-fallback",
    detail: qualityNote,
    at: Date.now(),
  };

  const variants = await variantsP;
  const best = [...variants].sort(
    (a, b) => (b.bitrateInKbps || 0) - (a.bitrateInKbps || 0)
  )[0];
  if (!best) throw new Error(`Нет downloadInfo для ${trackId}`);
  setLoad(
    "file",
    `Качаю ${best.bitrateInKbps || "?"} kbps · ${baseMeta.artists} — ${baseMeta.title}`
  );
  const bytes = await best.downloadBytes();
  const bitrateKbps = best.bitrateInKbps || 0;
  const codec = String(best.codec || "mp3");
  const quality: "lossless" | "hq" | "nq" =
    bitrateKbps >= 256 ? "hq" : bitrateKbps >= 160 ? "hq" : "nq";
  setLoad("ready", `Готово · ${baseMeta.title}`);
  return {
    bytes,
    meta: {
      ...baseMeta,
      codec,
      bitrateKbps,
      quality,
      qualityNote,
    },
  };
}

function readCachedTrack(trackId: string): {
  bytes: Uint8Array;
  meta: {
    id: string;
    title: string;
    artists: string;
    durationMs: number;
    coverUrl: string | null;
    codec: string;
    bitrateKbps: number;
    quality: "lossless" | "hq" | "nq";
    qualityNote?: string;
  };
} | null {
  if (!existsSync(cacheDir)) return null;
  const side = readdirSync(cacheDir).find((name) => name.endsWith(`-${trackId}.json`));
  if (!side) return null;
  try {
    const meta = JSON.parse(readFileSync(join(cacheDir, side), "utf8")) as {
      id: string;
      title: string;
      artists: string;
      durationMs: number;
      coverUrl: string | null;
      codec: string;
      bitrateKbps: number;
      quality: "lossless" | "hq" | "nq";
      qualityNote?: string;
      file: string;
    };
    const audioPath = join(cacheDir, meta.file);
    if (!existsSync(audioPath)) return null;
    return { bytes: readFileSync(audioPath), meta };
  } catch {
    return null;
  }
}

function extForMeta(meta: { codec: string; quality: string }): string {
  if (meta.quality === "lossless" || meta.codec.includes("flac")) return "flac";
  if (meta.codec.includes("aac") || meta.codec.includes("m4a")) return "m4a";
  return "mp3";
}

function cacheTrack(
  meta: {
    id: string;
    title: string;
    artists: string;
    durationMs: number;
    coverUrl: string | null;
    codec: string;
    bitrateKbps: number;
    quality: "lossless" | "hq" | "nq";
    qualityNote?: string;
  },
  bytes: Uint8Array,
  slot: string
) {
  const ext = extForMeta(meta);
  const name = `wave-${slot}-${meta.id}.${ext}`;
  writeFileSync(join(cacheDir, name), bytes);
  writeFileSync(
    join(cacheDir, `wave-${slot}-${meta.id}.json`),
    JSON.stringify({ ...meta, file: name }),
    "utf8"
  );
  return {
    ...meta,
    url: `/api/ym/cache/${name}`,
    fileName: `${meta.artists} - ${meta.title}.${ext}`,
  };
}

async function nextWaveTrack(client: Client) {
  if (waveCursor >= waveQueue.length) {
    setLoad("wave", "Ищу трек в Моей волне…");
    await ensureWaveBatch(client);
  }
  const item = waveQueue[waveCursor++]!;
  try {
    await client.rotorStationFeedbackTrackStarted(
      "user:onyourwave",
      item.id,
      waveBatchId
    );
  } catch {
    /* best-effort */
  }
  return downloadTrackBytes(client, item.id);
}

export function yandexLabPlugin(): Plugin {
  return {
    name: "automix-lab-yandex",
    configureServer(server) {
      if (!existsSync(cacheDir)) mkdirSync(cacheDir, { recursive: true });

      server.middlewares.use(async (req, res, next) => {
        const url = req.url || "";
        if (!url.startsWith("/api/ym/")) return next();

        try {
          if (url === "/api/ym/status" && req.method === "GET") {
            const t = readToken();
            const proxy = ymProxyUrl();
            return json(res, 200, {
              connected: Boolean(t?.accessToken),
              login: t?.login || null,
              pending: pending
                ? {
                    userCode: pending.userCode,
                    verificationUrl: pending.verificationUrl,
                    expiresAt: pending.expiresAt,
                  }
                : null,
              proxy: proxy ? { enabled: true } : { enabled: false },
              lossless: lastLosslessProbe,
              qualityHint:
                lastLosslessProbe?.used === "flac"
                  ? "FLAC активен"
                  : lastLosslessProbe?.used === "lossy-fallback"
                    ? "Яндекс отдал nq/192 вместо lossless — нужен IP РФ/РБ (YM_PROXY или локальный запуск)"
                    : null,
            });
          }

          if (url === "/api/ym/auth/start" && req.method === "POST") {
            const bare = buildClient();
            const code = await bare.requestDeviceCode(
              undefined,
              "Sonivo Automix Lab"
            );
            if (!code.deviceCode || !code.userCode || !code.verificationUrl) {
              return json(res, 502, { error: "device code incomplete" });
            }
            pending = {
              deviceCode: code.deviceCode,
              userCode: code.userCode,
              verificationUrl: code.verificationUrl,
              intervalMs: Math.max(3, code.interval || 5) * 1000,
              expiresAt: Date.now() + (code.expiresIn || 300) * 1000,
            };
            return json(res, 200, {
              userCode: pending.userCode,
              verificationUrl: pending.verificationUrl,
              expiresAt: pending.expiresAt,
              intervalMs: pending.intervalMs,
            });
          }

          if (url === "/api/ym/auth/poll" && req.method === "POST") {
            if (!pending) return json(res, 400, { error: "no pending auth" });
            if (Date.now() > pending.expiresAt) {
              pending = null;
              return json(res, 410, { error: "code expired — start again" });
            }
            const bare = buildClient();
            const token = await bare.pollDeviceToken(pending.deviceCode);
            if (!token?.accessToken) {
              return json(res, 202, { status: "pending" });
            }
            const client = await buildClient(token.accessToken).init();
            const login =
              client.me?.account?.login ||
              client.me?.account?.displayName ||
              "yandex";
            writeToken({
              accessToken: token.accessToken,
              refreshToken: token.refreshToken,
              expiresAt: token.expiresIn
                ? Date.now() + token.expiresIn * 1000
                : undefined,
              login: String(login),
            });
            pending = null;
            return json(res, 200, { status: "ok", login: String(login) });
          }

          if (url === "/api/ym/logout" && req.method === "POST") {
            clearToken();
            pending = null;
            waveQueue = [];
            waveCursor = 0;
            waveBatchId = undefined;
            return json(res, 200, { ok: true });
          }

          if (url === "/api/ym/wave/pair" && req.method === "POST") {
            const client = await clientFromToken();
            if (!client) return json(res, 401, { error: "not connected" });
            // Fresh batch for a clean A→B pair from Моя волна.
            waveQueue = [];
            waveCursor = 0;
            waveBatchId = undefined;
            await ensureWaveBatch(client);
            const a = await nextWaveTrack(client);
            const b = await nextWaveTrack(client);
            return json(res, 200, {
              a: cacheTrack(a.meta, a.bytes, "a"),
              b: cacheTrack(b.meta, b.bytes, "b"),
            });
          }

          // Continuous radio: one next track from Моя волна.
          if (url === "/api/ym/load" && req.method === "GET") {
            const elapsedSec = loadPhase.startedAt
              ? Math.max(0, (Date.now() - loadPhase.startedAt) / 1000)
              : 0;
            return json(res, 200, { ...loadPhase, elapsedSec });
          }

          if (url === "/api/ym/wave/next" && req.method === "POST") {
            const client = await clientFromToken();
            if (!client) return json(res, 401, { error: "not connected" });
            if (!waveQueue.length || waveCursor >= waveQueue.length) {
              await ensureWaveBatch(client);
            }
            const t = await nextWaveTrack(client);
            return json(res, 200, {
              track: cacheTrack(t.meta, t.bytes, `n${t.meta.id}`),
            });
          }

          if (url === "/api/ym/wave/reset" && req.method === "POST") {
            waveQueue = [];
            waveCursor = 0;
            waveBatchId = undefined;
            return json(res, 200, { ok: true });
          }

          // Timed lyrics (LRC) for karaoke sync — preferred over Whisper when available.
          if (url.startsWith("/api/ym/lyrics/") && req.method === "GET") {
            const client = await clientFromToken();
            if (!client) return json(res, 401, { error: "not connected" });
            const trackId = decodeURIComponent(
              url.slice("/api/ym/lyrics/".length).split("?")[0]!
            );
            if (!trackId) return json(res, 400, { error: "trackId required" });
            try {
              const lyrics = await client.tracksLyrics(trackId, "LRC");
              if (!lyrics) return json(res, 404, { error: "no lyrics" });
              const text = await lyrics.fetchLyrics();
              return json(res, 200, {
                trackId,
                format: "LRC",
                lrc: text,
              });
            } catch (e) {
              const msg = e instanceof Error ? e.message : String(e);
              return json(res, 404, { error: msg });
            }
          }

          if (url.startsWith("/api/ym/cache/") && req.method === "GET") {
            const name = decodeURIComponent(url.slice("/api/ym/cache/".length).split("?")[0]!);
            if (name.includes("..") || name.includes("/")) {
              return json(res, 400, { error: "bad path" });
            }
            const path = join(cacheDir, name);
            if (!existsSync(path)) return json(res, 404, { error: "missing" });
            const data = readFileSync(path);
            const lower = name.toLowerCase();
            const ctype = lower.endsWith(".flac")
              ? "audio/flac"
              : lower.endsWith(".m4a")
                ? "audio/mp4"
                : "audio/mpeg";
            res.statusCode = 200;
            res.setHeader("Content-Type", ctype);
            res.setHeader("Content-Length", String(data.length));
            res.setHeader("Cache-Control", "no-store");
            res.end(data);
            return;
          }

          // Rotor feedback: track finished after LAND (keeps Моя волна smart).
          if (url === "/api/ym/wave/finished" && req.method === "POST") {
            const client = await clientFromToken();
            if (!client) return json(res, 401, { error: "not connected" });
            const raw = await readBody(req);
            const body = JSON.parse(raw || "{}") as {
              trackId?: string;
              playedSec?: number;
            };
            if (!body.trackId) return json(res, 400, { error: "trackId required" });
            try {
              await client.rotorStationFeedbackTrackFinished(
                "user:onyourwave",
                body.trackId,
                Math.max(1, body.playedSec || 30),
                waveBatchId
              );
            } catch {
              /* best-effort */
            }
            return json(res, 200, { ok: true });
          }

          if (url === "/api/ym/wave/skip" && req.method === "POST") {
            const client = await clientFromToken();
            if (!client) return json(res, 401, { error: "not connected" });
            const raw = await readBody(req);
            const body = JSON.parse(raw || "{}") as {
              trackId?: string;
              playedSec?: number;
            };
            if (!body.trackId) return json(res, 400, { error: "trackId required" });
            try {
              await client.rotorStationFeedbackSkip(
                "user:onyourwave",
                body.trackId,
                Math.max(0, body.playedSec || 0),
                waveBatchId
              );
            } catch {
              /* best-effort */
            }
            return json(res, 200, { ok: true });
          }

          return json(res, 404, { error: "unknown ym route" });
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          return json(res, 500, { error: msg });
        }
      });
    },
  };
}
