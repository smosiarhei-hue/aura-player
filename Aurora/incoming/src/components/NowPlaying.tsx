import { useMemo, useRef } from "react";
import type { EngineSnapshot } from "../audio/engine";
import type { Track } from "../types";
import Artwork from "./Artwork";
import { cn } from "../utils/cn";

interface Props {
  track: Track | null;
  next: Track | null;
  snap: EngineSnapshot | null;
  onToggle: () => void;
  onNext: () => void;
  onPrev: () => void;
  onSeek: (t: number) => void;
  onMixNow: () => void;
}

const fmt = (s: number) => {
  if (!isFinite(s) || s < 0) s = 0;
  const m = Math.floor(s / 60);
  const sec = Math.floor(s % 60);
  return `${m}:${sec.toString().padStart(2, "0")}`;
};

export default function NowPlaying({ track, next, snap, onToggle, onNext, onPrev, onSeek, onMixNow }: Props) {
  const barRef = useRef<HTMLDivElement>(null);
  const a = track?.analysis ?? null;
  const pos = snap?.position ?? 0;
  const dur = track?.duration ?? 0;
  const pct = dur ? Math.min(100, (pos / dur) * 100) : 0;
  const tr = snap?.transition;
  const inTransition = !!tr?.active;

  const wave = useMemo(() => a?.waveform ?? new Array(160).fill(0.15), [a]);

  const handleSeek = (e: React.PointerEvent<HTMLDivElement>) => {
    const el = barRef.current;
    if (!el || !dur || inTransition) return;
    const rect = el.getBoundingClientRect();
    const x = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
    onSeek(x * dur);
  };

  const liveBpm = snap?.effectiveBpm ?? a?.bpm ?? 0;

  return (
    <section className="glass rounded-3xl p-4">
      <div className="flex gap-4">
        <div className="relative shrink-0">
          <Artwork track={track} className={cn("h-28 w-28 shadow-2xl transition-transform duration-700", snap?.playing ? "scale-100" : "scale-95")} />
          {inTransition && next && (
            <Artwork
              track={next}
              className="absolute -right-2 -bottom-2 h-12 w-12 ring-2 ring-white/20 shadow-xl"
              size="sm"
            />
          )}
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 text-[11px] font-medium uppercase tracking-widest text-white/40">
            <span className={cn("inline-block h-1.5 w-1.5 rounded-full", snap?.playing ? "bg-emerald-400 animate-pulse" : "bg-white/30")} />
            {inTransition ? "AutoMix · переход" : snap?.playing ? "Играет" : "Пауза"}
            <span className="ml-auto rounded-md bg-white/10 px-1.5 py-0.5 font-semibold text-white/70">Дека {snap?.activeDeck ?? "A"}</span>
          </div>
          <h2 className="mt-1 truncate text-xl font-semibold tracking-tight text-white">{track?.title ?? "Выберите трек"}</h2>
          <p className="truncate text-sm text-white/50">{track?.artist ?? "Библиотека пуста — добавьте файлы или демо-сет"}</p>

          <div className="mt-3 flex flex-wrap gap-1.5">
            <Chip label="BPM" value={a ? liveBpm.toFixed(1) : "—"} accent={inTransition && Math.abs((tr?.tempoShift ?? 0)) > 0.1} />
            <Chip label="Тон" value={a ? a.camelot : "—"} sub={a?.key} />
            <Chip label="Жанр" value={a?.genre ?? "—"} />
            <Chip label="Энергия" value={a ? `${Math.round(a.energy * 100)}` : "—"} />
          </div>
        </div>
      </div>

      {/* Волновая форма */}
      <div
        ref={barRef}
        onPointerDown={handleSeek}
        className={cn("relative mt-4 h-14 w-full select-none overflow-hidden rounded-xl bg-white/5", inTransition ? "cursor-not-allowed" : "cursor-pointer")}
      >
        <div className="absolute inset-0 flex items-end gap-px px-1 pb-1">
          {wave.map((v, i) => {
            const played = (i / wave.length) * 100 <= pct;
            return (
              <div
                key={i}
                className="flex-1 rounded-sm transition-colors"
                style={{
                  height: `${Math.max(6, v * 92)}%`,
                  background: played ? `linear-gradient(to top, ${track?.color2 ?? "#818cf8"}, ${track?.color ?? "#c4b5fd"})` : "rgba(255,255,255,0.18)",
                }}
              />
            );
          })}
        </div>
        {a && dur > 0 && (
          <>
            <Marker at={(a.mixIn / dur) * 100} label="in" />
            <Marker at={(a.mixOut / dur) * 100} label="mix" warn />
          </>
        )}
        <div className="absolute top-0 bottom-0 w-px bg-white shadow-[0_0_8px_rgba(255,255,255,.8)]" style={{ left: `${pct}%` }} />
      </div>
      <div className="mt-1.5 flex justify-between font-mono text-[11px] text-white/40">
        <span>{fmt(pos)}</span>
        {a && <span className="text-white/30">до микса {fmt(Math.max(0, a.mixOut - pos))}</span>}
        <span>-{fmt(dur - pos)}</span>
      </div>

      {/* Управление */}
      <div className="mt-3 flex items-center justify-between">
        <button onClick={onPrev} className="btn-icon" aria-label="Предыдущий">
          <svg viewBox="0 0 24 24" className="h-6 w-6 fill-current"><path d="M6 6h2v12H6zm3.5 6 8.5 6V6z" /></svg>
        </button>
        <button onClick={onToggle} disabled={!track} className="btn-play" aria-label="Играть/пауза">
          {snap?.playing ? (
            <svg viewBox="0 0 24 24" className="h-8 w-8 fill-current"><path d="M6 5h4v14H6zm8 0h4v14h-4z" /></svg>
          ) : (
            <svg viewBox="0 0 24 24" className="h-8 w-8 translate-x-0.5 fill-current"><path d="M8 5v14l11-7z" /></svg>
          )}
        </button>
        <button onClick={onNext} className="btn-icon" aria-label="Следующий">
          <svg viewBox="0 0 24 24" className="h-6 w-6 fill-current"><path d="M16 6h2v12h-2zM6 18l8.5-6L6 6z" /></svg>
        </button>
      </div>
      <button
        onClick={onMixNow}
        disabled={!next || inTransition || !snap?.playing}
        className="mt-3 w-full rounded-xl bg-gradient-to-r from-fuchsia-500/80 to-indigo-500/80 py-2.5 text-sm font-semibold text-white shadow-lg shadow-indigo-900/40 transition active:scale-[0.98] disabled:opacity-30"
      >
        {inTransition ? `Переход ${Math.round((tr?.progress ?? 0) * 100)}%` : "Свести сейчас →"}
      </button>
    </section>
  );
}

function Chip({ label, value, sub, accent }: { label: string; value: string; sub?: string; accent?: boolean }) {
  return (
    <div className={cn("flex items-baseline gap-1 rounded-lg px-2 py-1 text-xs", accent ? "bg-fuchsia-500/30 text-fuchsia-100" : "bg-white/8 text-white/80")} title={sub}>
      <span className="text-[10px] uppercase tracking-wider text-white/40">{label}</span>
      <span className="font-semibold tabular-nums">{value}</span>
    </div>
  );
}

function Marker({ at, label, warn }: { at: number; label: string; warn?: boolean }) {
  return (
    <div className="absolute top-0 bottom-0" style={{ left: `${at}%` }}>
      <div className={cn("h-full w-px", warn ? "bg-amber-400/80" : "bg-emerald-400/80")} />
      <span className={cn("absolute top-0.5 left-1 text-[9px] font-semibold uppercase", warn ? "text-amber-300" : "text-emerald-300")}>{label}</span>
    </div>
  );
}
