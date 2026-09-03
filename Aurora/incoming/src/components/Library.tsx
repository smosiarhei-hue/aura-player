import { memo, useRef } from "react";
import type { Track } from "../types";
import Artwork from "./Artwork";
import { cn } from "../utils/cn";

interface Props {
  tracks: Track[];
  currentId: string | null;
  nextId: string | null;
  demoProgress: { done: number; total: number } | null;
  onPlay: (t: Track) => void;
  onRemove: (t: Track) => void;
  onAddFiles: (files: FileList) => void;
  onLoadDemo: () => void;
  onSetNext: (t: Track) => void;
}

export default memo(Library);

function Library({ tracks, currentId, nextId, demoProgress, onPlay, onRemove, onAddFiles, onLoadDemo, onSetNext }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const hasDemo = tracks.some((t) => t.source === "demo");

  return (
    <section className="glass rounded-3xl p-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-white">
          Библиотека <span className="ml-1 text-white/40">{tracks.length}</span>
        </h3>
        <div className="flex gap-2">
          {!hasDemo && (
            <button
              onClick={onLoadDemo}
              disabled={!!demoProgress}
              className="rounded-lg bg-white/10 px-2.5 py-1.5 text-xs font-medium text-white/80 transition hover:bg-white/15 disabled:opacity-50"
            >
              {demoProgress ? `Демо ${demoProgress.done}/${demoProgress.total}` : "Демо-сет"}
            </button>
          )}
          <button
            onClick={() => inputRef.current?.click()}
            className="rounded-lg bg-white px-2.5 py-1.5 text-xs font-semibold text-black transition hover:bg-white/90"
          >
            + Файлы
          </button>
          <input
            ref={inputRef}
            type="file"
            accept="audio/*,.mp3,.m4a,.aac,.wav,.flac,.ogg"
            multiple
            className="hidden"
            onChange={(e) => {
              if (e.target.files?.length) onAddFiles(e.target.files);
              e.target.value = "";
            }}
          />
        </div>
      </div>

      {tracks.length === 0 && !demoProgress && (
        <div className="mt-4 rounded-2xl border border-dashed border-white/15 p-6 text-center">
          <div className="text-3xl">🎧</div>
          <p className="mt-2 text-sm text-white/70">Добавьте свои треки (mp3, m4a, wav, flac)</p>
          <p className="mt-1 text-xs text-white/40">Они сохраняются на устройстве и анализируются офлайн: BPM, тональность, энергия, точки микса.</p>
        </div>
      )}

      {demoProgress && (
        <div className="mt-3 rounded-xl bg-white/5 p-3 text-xs text-white/60">
          Синтезирую демо-треки… {demoProgress.done}/{demoProgress.total}
          <div className="mt-2 h-1 overflow-hidden rounded-full bg-white/10">
            <div className="h-full bg-indigo-400 transition-all" style={{ width: `${(demoProgress.done / demoProgress.total) * 100}%` }} />
          </div>
        </div>
      )}

      <ul className="mt-3 space-y-1">
        {tracks.map((t) => {
          const isCur = t.id === currentId;
          const isNext = t.id === nextId;
          const a = t.analysis;
          return (
            <li
              key={t.id}
              className={cn(
                "group flex items-center gap-3 rounded-xl px-2 py-2 transition",
                isCur ? "bg-white/12" : "hover:bg-white/6",
              )}
            >
              <button onClick={() => onPlay(t)} className="flex min-w-0 flex-1 items-center gap-3 text-left">
                <Artwork track={t} className="h-11 w-11 shrink-0" size="sm" />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5">
                    <span className={cn("truncate text-sm font-medium", isCur ? "text-white" : "text-white/90")}>{t.title}</span>
                    {isCur && <span className="shrink-0 text-[9px] font-bold uppercase text-emerald-300">● live</span>}
                    {isNext && !isCur && <span className="shrink-0 text-[9px] font-bold uppercase text-fuchsia-300">next</span>}
                  </div>
                  <div className="truncate text-xs text-white/45">{t.artist}</div>
                  <div className="mt-0.5 flex items-center gap-2 font-mono text-[10px] text-white/50">
                    {t.analyzing || !a ? (
                      <span className="flex items-center gap-1 text-indigo-300">
                        <span className="inline-block h-1.5 w-1.5 animate-ping rounded-full bg-indigo-300" /> анализ DSP…
                      </span>
                    ) : (
                      <>
                        <span className="text-white/80">{a.bpm.toFixed(0)} BPM</span>
                        <span>{a.camelot}</span>
                        <span>{a.genre}</span>
                        <EnergyBar v={a.energy} />
                      </>
                    )}
                  </div>
                </div>
              </button>
              <div className="flex shrink-0 items-center gap-1">
                {!isCur && a && (
                  <button
                    onClick={() => onSetNext(t)}
                    title="Поставить следующим"
                    className="rounded-lg p-1.5 text-white/40 opacity-0 transition group-hover:opacity-100 hover:bg-white/10 hover:text-white"
                  >
                    <svg viewBox="0 0 24 24" className="h-4 w-4 fill-current"><path d="M4 6h12v2H4zm0 4h12v2H4zm0 4h8v2H4zm14-4v4h-3l4 4 4-4h-3v-4z" /></svg>
                  </button>
                )}
                <button
                  onClick={() => onRemove(t)}
                  title="Удалить"
                  className="rounded-lg p-1.5 text-white/30 opacity-0 transition group-hover:opacity-100 hover:bg-white/10 hover:text-rose-300"
                >
                  <svg viewBox="0 0 24 24" className="h-4 w-4 fill-current"><path d="M6 7h12l-1 14H7zm3-3h6l1 2H8z" /></svg>
                </button>
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function EnergyBar({ v }: { v: number }) {
  return (
    <span className="ml-auto flex h-2 w-10 items-end gap-px">
      {[0.2, 0.4, 0.6, 0.8, 1].map((th) => (
        <span key={th} className={cn("flex-1 rounded-sm", v >= th - 0.1 ? "bg-emerald-400" : "bg-white/15")} style={{ height: `${th * 100}%` }} />
      ))}
    </span>
  );
}
