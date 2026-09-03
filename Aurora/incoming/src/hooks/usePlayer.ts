import { useCallback, useEffect, useRef, useState } from "react";
import { analyzeBuffer } from "../audio/analysis";
import { DEMO_SPECS, renderDemo } from "../audio/demo";
import { AutoMixEngine, type EngineSnapshot } from "../audio/engine";
import { pickNext } from "../audio/similarity";
import { deleteTrack, loadSettings, loadTracks, saveSettings, saveTrack, updateAnalysis } from "../audio/storage";
import type { Genre, MixSettings, Track } from "../types";

export const DEFAULT_SETTINGS: MixSettings = {
  style: "club",
  lengthBeats: 16,
  beatmatch: true,
  keyMatch: true,
  wave: true,
  eqSwap: true,
  autoGain: true,
};

const PALETTE: [string, string][] = [
  ["#f472b6", "#4c1d95"],
  ["#34d399", "#064e3b"],
  ["#60a5fa", "#1e3a8a"],
  ["#fbbf24", "#7c2d12"],
  ["#a78bfa", "#312e81"],
  ["#fb7185", "#881337"],
  ["#2dd4bf", "#134e4a"],
  ["#f97316", "#431407"],
];

function hashColor(s: string): [string, string] {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

function parseName(filename: string): { title: string; artist: string } {
  const base = filename.replace(/\.[^.]+$/, "");
  const m = base.split(/\s+[-–—]\s+/);
  if (m.length >= 2) return { artist: m[0].trim(), title: m.slice(1).join(" - ").trim() };
  return { title: base, artist: "Неизвестный исполнитель" };
}

export function usePlayer() {
  const engineRef = useRef<AutoMixEngine | null>(null);
  const [tracks, setTracks] = useState<Track[]>([]);
  const tracksRef = useRef<Track[]>([]);
  tracksRef.current = tracks;

  const [settings, setSettingsState] = useState<MixSettings>(() => loadSettings(DEFAULT_SETTINGS));
  const settingsRef = useRef(settings);
  settingsRef.current = settings;

  const [currentId, setCurrentId] = useState<string | null>(null);
  const [nextId, setNextId] = useState<string | null>(null);
  const historyRef = useRef<string[]>([]);
  const [snap, setSnap] = useState<EngineSnapshot | null>(null);
  const [demoProgress, setDemoProgress] = useState<{ done: number; total: number } | null>(null);
  const [ready, setReady] = useState(false);

  const getEngine = useCallback(() => {
    if (!engineRef.current) {
      const e = new AutoMixEngine(settingsRef.current);
      e.on((evt) => {
        if (evt.type === "trackChange" && evt.track) {
          setCurrentId(evt.track.id);
          historyRef.current = [...historyRef.current.slice(-50), evt.track.id];
          setNextId(null);
        }
        if (evt.type === "ended") {
          // Дошли до конца без следующего — переходим на первый доступный
          const pool = tracksRef.current.filter((t) => t.buffer && t.analysis && t.id !== evt.track?.id);
          if (pool.length && settingsRef.current.wave) e.play(pool[0]);
        }
      });
      engineRef.current = e;
    }
    return engineRef.current;
  }, []);

  /* ---------- обновление объектов трека внутри движка (после анализа) ---------- */
  useEffect(() => {
    const e = engineRef.current;
    if (!e) return;
    for (const d of Object.values(e.decks)) {
      if (d.track) {
        const fresh = tracks.find((t) => t.id === d.track!.id);
        if (fresh && fresh !== d.track) d.track = fresh;
      }
    }
  }, [tracks]);

  /* ---------- выбор следующего ---------- */
  useEffect(() => {
    const e = engineRef.current;
    const current = tracks.find((t) => t.id === currentId) ?? null;
    const valid = nextId ? tracks.find((t) => t.id === nextId && t.analysis && t.buffer && t.id !== currentId) : null;
    if (valid) {
      if (e) e.nextTrack = valid;
      return;
    }
    if (!current) {
      if (e) e.nextTrack = null;
      return;
    }
    let next: Track | null = null;
    if (settings.wave) {
      next = pickNext(current, tracks, historyRef.current, settings);
    } else {
      const ready = tracks.filter((t) => t.analysis && t.buffer);
      const idx = ready.findIndex((t) => t.id === current.id);
      if (ready.length > 1) next = ready[(idx + 1) % ready.length];
    }
    if (next?.id !== nextId) setNextId(next?.id ?? null);
    if (e) e.nextTrack = next;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tracks, currentId, nextId, settings.wave, settings.beatmatch, settings.keyMatch]);

  /* ---------- цикл обновления движка ---------- */
  useEffect(() => {
    let last = 0;
    const id = window.setInterval(() => {
      const e = engineRef.current;
      if (!e) return;
      const s = e.update();
      const now = performance.now();
      if (now - last > 66) {
        last = now;
        setSnap(s);
      }
    }, 33);
    return () => window.clearInterval(id);
  }, []);

  /* ---------- настройки ---------- */
  const setSettings = useCallback((s: MixSettings) => {
    setSettingsState(s);
    saveSettings(s);
    if (engineRef.current) engineRef.current.settings = s;
  }, []);

  /* ---------- добавление и анализ ---------- */
  const upsert = useCallback((t: Track) => {
    setTracks((prev) => {
      const i = prev.findIndex((x) => x.id === t.id);
      if (i === -1) return [...prev, t];
      const copy = prev.slice();
      copy[i] = t;
      return copy;
    });
  }, []);

  const runAnalysis = useCallback(
    async (track: Track, genreOverride?: Genre) => {
      if (!track.buffer) return;
      try {
        const analysis = await analyzeBuffer(track.id, track.buffer);
        if (genreOverride) analysis.genre = genreOverride;
        const updated = { ...track, analysis, analyzing: false };
        upsert(updated);
        if (track.source === "file") void updateAnalysis(track.id, analysis);
      } catch (err) {
        console.error("analysis failed", err);
        upsert({ ...track, analyzing: false });
      }
    },
    [upsert],
  );

  const addFiles = useCallback(
    async (files: FileList) => {
      const e = getEngine();
      for (const file of Array.from(files)) {
        const id = crypto.randomUUID ? crypto.randomUUID() : `f-${Date.now()}-${Math.random()}`;
        const { title, artist } = parseName(file.name);
        const [color, color2] = hashColor(file.name);
        try {
          const buf = await e.ctx.decodeAudioData(await file.arrayBuffer());
          const track: Track = { id, title, artist, duration: buf.duration, source: "file", buffer: buf, analysis: null, analyzing: true, color, color2 };
          upsert(track);
          void saveTrack({ id, title, artist, blob: file, analysis: null, color, color2, addedAt: Date.now() });
          void runAnalysis(track);
        } catch (err) {
          console.error("decode failed", file.name, err);
        }
      }
    },
    [getEngine, upsert, runAnalysis],
  );

  const loadDemo = useCallback(async () => {
    setDemoProgress({ done: 0, total: DEMO_SPECS.length });
    for (let i = 0; i < DEMO_SPECS.length; i++) {
      const spec = DEMO_SPECS[i];
      if (tracksRef.current.some((t) => t.id === spec.id)) continue;
      try {
        const buf = await renderDemo(spec);
        const track: Track = {
          id: spec.id,
          title: spec.title,
          artist: spec.artist,
          duration: buf.duration,
          source: "demo",
          buffer: buf,
          analysis: null,
          analyzing: true,
          color: spec.color,
          color2: spec.color2,
        };
        upsert(track);
        void runAnalysis(track, spec.genre);
      } catch (err) {
        console.error("demo render failed", err);
      }
      setDemoProgress({ done: i + 1, total: DEMO_SPECS.length });
    }
    setDemoProgress(null);
  }, [upsert, runAnalysis]);

  /* ---------- восстановление библиотеки ---------- */
  const bootRef = useRef(false);
  useEffect(() => {
    if (bootRef.current) return;
    bootRef.current = true;
    (async () => {
      const stored = await loadTracks();
      const e = getEngine();
      for (const s of stored) {
        try {
          const buf = await e.ctx.decodeAudioData(await s.blob.arrayBuffer());
          const track: Track = {
            id: s.id,
            title: s.title,
            artist: s.artist,
            duration: buf.duration,
            source: "file",
            buffer: buf,
            analysis: s.analysis,
            analyzing: !s.analysis,
            color: s.color,
            color2: s.color2,
          };
          upsert(track);
          if (!s.analysis) void runAnalysis(track);
        } catch (err) {
          console.error("restore failed", s.title, err);
        }
      }
      setReady(true);
      if (stored.length === 0) void loadDemo();
    })();
  }, [getEngine, upsert, runAnalysis, loadDemo]);

  /* ---------- действия ---------- */
  const play = useCallback(
    async (t: Track) => {
      const e = getEngine();
      await e.play(t);
    },
    [getEngine],
  );

  const toggle = useCallback(async () => {
    const e = getEngine();
    if (!e.currentTrack) {
      const first = tracksRef.current.find((t) => t.buffer);
      if (first) await e.play(first);
      return;
    }
    await e.togglePlay();
  }, [getEngine]);

  const next = useCallback(async () => {
    const e = getEngine();
    const target = tracksRef.current.find((t) => t.id === nextId && t.analysis) ?? e.nextTrack;
    if (!target) return;
    if (e.playing && e.currentTrack?.analysis) {
      if (!e.startTransition(target, e.settings.style === "smooth" ? "club" : e.settings.style)) await e.play(target, true);
    } else {
      await e.play(target);
    }
  }, [getEngine, nextId]);

  const prev = useCallback(async () => {
    const e = getEngine();
    const pos = e.activeDeck.position();
    if (pos > 5 || historyRef.current.length < 2) {
      e.seek(0);
      return;
    }
    const prevId = historyRef.current[historyRef.current.length - 2];
    const t = tracksRef.current.find((x) => x.id === prevId);
    if (t) {
      historyRef.current = historyRef.current.slice(0, -2);
      await e.play(t);
    }
  }, [getEngine]);

  const mixNow = useCallback(() => {
    const e = getEngine();
    e.startTransition();
  }, [getEngine]);

  const seek = useCallback((t: number) => getEngine().seek(t), [getEngine]);

  const remove = useCallback(
    async (t: Track) => {
      setTracks((prev) => prev.filter((x) => x.id !== t.id));
      if (t.source === "file") await deleteTrack(t.id);
      if (nextId === t.id) setNextId(null);
    },
    [nextId],
  );

  const setNext = useCallback((t: Track) => setNextId(t.id), []);

  /* ---------- MediaSession (экран блокировки iOS) ---------- */
  const current = tracks.find((t) => t.id === currentId) ?? null;
  useEffect(() => {
    if (!("mediaSession" in navigator) || !current) return;
    try {
      navigator.mediaSession.metadata = new MediaMetadata({ title: current.title, artist: current.artist, album: "AutoMix DSP" });
      navigator.mediaSession.setActionHandler("play", () => void toggle());
      navigator.mediaSession.setActionHandler("pause", () => void toggle());
      navigator.mediaSession.setActionHandler("nexttrack", () => void next());
      navigator.mediaSession.setActionHandler("previoustrack", () => void prev());
    } catch {
      /* ignore */
    }
  }, [current, toggle, next, prev]);

  useEffect(() => {
    if (!("mediaSession" in navigator)) return;
    navigator.mediaSession.playbackState = snap?.playing ? "playing" : "paused";
  }, [snap?.playing]);

  const nextTrack = tracks.find((t) => t.id === nextId) ?? null;

  return {
    engine: engineRef.current,
    tracks,
    current,
    nextTrack,
    snap,
    settings,
    setSettings,
    demoProgress,
    ready,
    actions: { play, toggle, next, prev, mixNow, seek, remove, addFiles, loadDemo, setNext },
  };
}
