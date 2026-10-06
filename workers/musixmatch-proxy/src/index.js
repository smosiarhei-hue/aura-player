const API_BASE = "https://api.musixmatch.com/ws/1.1";
const CACHE_SECONDS = 300;

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET") return response({ error: "method_not_allowed" }, 405);
    if (!env.MUSIXMATCH_API_KEY) return response({ error: "proxy_not_configured" }, 503);

    const url = new URL(request.url);
    try {
      const result = await route(url, env.MUSIXMATCH_API_KEY, ctx);
      return result instanceof Response ? result : response(result);
    } catch (error) {
      const status = Number(error?.status) || 502;
      return response({ error: "musixmatch_request_failed", status }, status);
    }
  },
};

async function route(url, apiKey, ctx) {
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const segments = path.split("/").filter(Boolean);

  if (path === "/health") return { ok: true };

  if (path === "/search") {
    const title = required(url, "title");
    const artist = required(url, "artist");
    const body = await call("matcher.track.get", { q_track: title, q_artist: artist }, apiKey, ctx);
    const track = body?.track;
    if (!track) throw withStatus(404);
    return {
      track_id: track.track_id,
      name: track.track_name || title,
      artist: track.artist_name || artist,
      has_richsync: track.has_richsync || 0,
      has_subtitles: track.has_subtitles || 0,
      commontrack_id: track.commontrack_id || null,
    };
  }

  if (path === "/matcher/lyrics") {
    return call("matcher.lyrics.get", matcherParams(url), apiKey, ctx);
  }
  if (path === "/matcher/subtitle") {
    return call("matcher.subtitle.get", {
      ...matcherParams(url),
      subtitle_format: url.searchParams.get("format") || "lrc",
    }, apiKey, ctx);
  }
  if (path === "/track/search") {
    return call("track.search", compact({
      q: url.searchParams.get("q"),
      q_track: url.searchParams.get("title"),
      q_artist: url.searchParams.get("artist"),
      q_lyrics: url.searchParams.get("lyrics"),
      page: integer(url, "page", 1, 1, 100),
      page_size: integer(url, "page_size", 10, 1, 100),
    }), apiKey, ctx);
  }
  if (path === "/track/get") {
    const identifiers = compact({
      track_id: url.searchParams.get("track_id"),
      commontrack_id: url.searchParams.get("commontrack_id"),
      track_isrc: url.searchParams.get("isrc"),
      track_spotify_id: url.searchParams.get("spotify_id"),
    });
    if (Object.keys(identifiers).length !== 1) throw withStatus(400);
    return call("track.get", identifiers, apiKey, ctx);
  }
  if (path === "/chart/tracks") {
    return call("chart.tracks.get", {
      country: url.searchParams.get("country") || "us",
      page: integer(url, "page", 1, 1, 100),
      page_size: integer(url, "page_size", 10, 1, 100),
    }, apiKey, ctx);
  }
  if (path === "/artist/search") {
    return call("artist.search", {
      q_artist: required(url, "artist"),
      page: integer(url, "page", 1, 1, 100),
      page_size: integer(url, "page_size", 10, 1, 100),
    }, apiKey, ctx);
  }

  const id = positiveID(segments[1]);
  if (segments[0] === "track" && segments.length === 2) {
    return call("track.get", { track_id: id }, apiKey, ctx);
  }
  if (segments[0] === "lyrics" && segments.length === 2) {
    return call("track.lyrics.get", { track_id: id }, apiKey, ctx);
  }
  if (segments[0] === "lyrics" && segments[2] === "translation") {
    return call("track.lyrics.translation.get", {
      track_id: id,
      language: required(url, "language"),
    }, apiKey, ctx);
  }
  if (segments[0] === "snippet" && segments.length === 2) {
    return call("track.snippet.get", { track_id: id }, apiKey, ctx);
  }
  if (segments[0] === "subtitle" && segments.length === 2) {
    const body = await call("track.subtitle.get", {
      track_id: id,
      subtitle_format: url.searchParams.get("format") || "lrc",
    }, apiKey, ctx);
    const text = body?.subtitle?.subtitle_body;
    if (!text) throw withStatus(404);
    return new Response(text, { headers: textHeaders() });
  }
  if (segments[0] === "subtitle" && segments[2] === "translation") {
    return call("track.subtitle.translation.get", {
      track_id: id,
      language: required(url, "language"),
      subtitle_format: url.searchParams.get("format") || "lrc",
    }, apiKey, ctx);
  }
  if (segments[0] === "richsync" && segments.length === 2) {
    const body = await call("track.richsync.get", { track_id: id }, apiKey, ctx);
    const raw = body?.richsync?.richsync_body;
    if (!raw) throw withStatus(404);
    return new Response(raw, { headers: jsonHeaders() });
  }
  if (segments[0] === "artist" && segments.length === 2) {
    return call("artist.get", { artist_id: id }, apiKey, ctx);
  }
  if (segments[0] === "album" && segments.length === 2) {
    return call("album.get", { album_id: id }, apiKey, ctx);
  }

  throw withStatus(404);
}

async function call(method, params, apiKey, ctx) {
  const upstream = new URL(`${API_BASE}/${method}`);
  for (const [key, value] of Object.entries(compact(params))) {
    upstream.searchParams.set(key, String(value));
  }
  upstream.searchParams.set("apikey", apiKey);

  const cacheKey = new Request(upstream.toString(), { method: "GET" });
  const cache = caches.default;
  const cached = await cache.match(cacheKey);
  if (cached) return cached.json();

  const upstreamResponse = await fetch(upstream, {
    headers: { Accept: "application/json", "User-Agent": "Sonivo-Musixmatch-Proxy/1.0" },
  });
  if (!upstreamResponse.ok) throw withStatus(upstreamResponse.status);
  const payload = await upstreamResponse.json();
  const header = payload?.message?.header || {};
  if (header.status_code !== 200) throw withStatus(header.status_code || 502);
  const body = payload?.message?.body || {};

  const cachedResponse = response(body);
  ctx.waitUntil(cache.put(cacheKey, cachedResponse.clone()));
  return body;
}

function matcherParams(url) {
  return { q_track: required(url, "title"), q_artist: required(url, "artist") };
}
function required(url, name) {
  const value = url.searchParams.get(name)?.trim();
  if (!value) throw withStatus(400);
  return value.slice(0, 200);
}
function integer(url, name, fallback, min, max) {
  const value = Number(url.searchParams.get(name) || fallback);
  return Math.min(max, Math.max(min, Number.isFinite(value) ? Math.trunc(value) : fallback));
}
function positiveID(raw) {
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) throw withStatus(400);
  return value;
}
function compact(value) {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== null && item !== undefined && item !== ""));
}
function withStatus(status) {
  return Object.assign(new Error(String(status)), { status });
}
function jsonHeaders() {
  return { "Content-Type": "application/json; charset=utf-8", "Cache-Control": `public, max-age=${CACHE_SECONDS}` };
}
function textHeaders() {
  return { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": `public, max-age=${CACHE_SECONDS}` };
}
function response(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders() });
}
