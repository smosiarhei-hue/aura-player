import { reasons } from "../audio/similarity";
import type { Track, TransitionState } from "../types";
import Artwork from "./Artwork";
import { cn } from "../utils/cn";

interface Props {
  current: Track | null;
  next: Track | null;
  wave: boolean;
  transition: TransitionState | null;
  levels: { A: number; B: number };
  activeDeck: "A" | "B";
}

export default function UpNext({ current, next, wave, transition, levels, activeDeck }: Props) {
  const rs = current?.analysis && next?.analysis ? reasons(current.analysis, next.analysis) : [];
  const active = transition?.active;
  const incomingDeck = activeDeck === "A" ? "B" : "A";

  return (
    <section className="glass rounded-3xl p-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-white">{wave ? "Далее в волне" : "Далее по очереди"}</h3>
        {wave && <span className="text-[10px] uppercase tracking-wider text-fuchsia-300">◉ моя волна</span>}
      </div>

      {next ? (
        <div className="mt-3 flex items-center gap-3">
          <Artwork track={next} className="h-12 w-12 shrink-0" size="sm" />
          <div className="min-w-0 flex-1">
            <div className="truncate text-sm font-semibold text-white">{next.title}</div>
            <div className="truncate text-xs text-white/50">{next.artist}</div>
            <div className="mt-1 flex flex-wrap gap-1">
              {rs.map((r) => (
                <span
                  key={r.label}
                  className={cn("rounded px-1.5 py-0.5 text-[10px] font-medium", r.ok ? "bg-emerald-500/15 text-emerald-300" : "bg-amber-500/15 text-amber-300")}
                >
                  {r.ok ? "✓ " : "~ "}
                  {r.label}
                </span>
              ))}
            </div>
          </div>
        </div>
      ) : (
        <p className="mt-2 text-xs text-white/40">Нужен ещё хотя бы один проанализированный трек.</p>
      )}

      {/* Деки */}
      <div className="mt-4 grid grid-cols-2 gap-2">
        {(["A", "B"] as const).map((d) => {
          const isActive = d === activeDeck;
          const isIncoming = active && d === incomingDeck;
          return (
            <div key={d} className={cn("rounded-xl p-2.5", isActive || isIncoming ? "bg-white/10" : "bg-white/4")}>
              <div className="flex items-center justify-between text-[10px] uppercase tracking-wider text-white/50">
                <span>Дека {d}</span>
                <span className={cn(isActive ? "text-emerald-300" : isIncoming ? "text-fuchsia-300" : "text-white/30")}>
                  {isActive ? (active ? "уходит" : "live") : isIncoming ? "входит" : "idle"}
                </span>
              </div>
              <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-white/10">
                <div
                  className={cn("h-full rounded-full transition-[width] duration-75", isIncoming ? "bg-fuchsia-400" : "bg-emerald-400")}
                  style={{ width: `${Math.min(100, levels[d] * 130)}%` }}
                />
              </div>
            </div>
          );
        })}
      </div>

      {active && transition && (
        <div className="mt-3 rounded-xl bg-gradient-to-r from-fuchsia-500/15 to-indigo-500/15 p-3 ring-1 ring-fuchsia-400/20">
          <div className="flex justify-between text-[11px] text-white/70">
            <span>
              Переход · {labelStyle(transition.style)} · {transition.duration.toFixed(1)} с
            </span>
            <span className="font-mono">
              {transition.tempoShift >= 0 ? "+" : ""}
              {transition.tempoShift.toFixed(1)}% темп
            </span>
          </div>
          <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-white/10">
            <div className="h-full bg-gradient-to-r from-emerald-400 via-fuchsia-400 to-indigo-400" style={{ width: `${transition.progress * 100}%` }} />
          </div>
        </div>
      )}
    </section>
  );
}

function labelStyle(s: TransitionState["style"]) {
  return { smooth: "плавный", club: "клуб", echo: "эхо", cut: "кат" }[s];
}
