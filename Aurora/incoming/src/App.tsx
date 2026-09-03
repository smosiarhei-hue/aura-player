import { useEffect, useState } from "react";
import Library from "./components/Library";
import MixControls from "./components/MixControls";
import NowPlaying from "./components/NowPlaying";
import UpNext from "./components/UpNext";
import Visualizer from "./components/Visualizer";
import { usePlayer } from "./hooks/usePlayer";

export default function App() {
  const { engine, tracks, current, nextTrack, snap, settings, setSettings, demoProgress, actions } = usePlayer();
  const [online, setOnline] = useState(navigator.onLine);

  useEffect(() => {
    const on = () => setOnline(true);
    const off = () => setOnline(false);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
    };
  }, []);

  const c1 = current?.color ?? "#6366f1";
  const c2 = current?.color2 ?? "#0f172a";
  const inTransition = snap?.transition.active;
  const nextC = nextTrack?.color ?? c1;

  return (
    <div className="relative min-h-screen overflow-hidden bg-[#07070c] text-white">
      {/* Фон, реагирующий на трек */}
      <div
        className="pointer-events-none absolute inset-0 transition-all duration-[1500ms]"
        style={{
          background: `radial-gradient(60% 45% at 15% 0%, ${c1}55 0%, transparent 70%), radial-gradient(50% 40% at 90% 15%, ${inTransition ? nextC : c2}66 0%, transparent 70%), radial-gradient(70% 50% at 50% 100%, ${c2}44 0%, transparent 70%)`,
        }}
      />
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(rgba(255,255,255,0.035)_1px,transparent_1px)] [background-size:22px_22px]" />

      <main className="relative mx-auto flex min-h-screen w-full max-w-md flex-col gap-3 px-4 pb-10 pt-[max(1rem,env(safe-area-inset-top))]">
        {/* Заголовок */}
        <header className="flex items-center justify-between px-1 pt-2">
          <div>
            <div className="flex items-center gap-2">
              <span className="grid h-8 w-8 place-items-center rounded-xl bg-gradient-to-br from-fuchsia-500 to-indigo-600 text-sm font-black shadow-lg shadow-fuchsia-900/40">
                ∿
              </span>
              <h1 className="text-lg font-bold tracking-tight">AutoMix DSP</h1>
            </div>
            <p className="mt-0.5 text-[11px] text-white/40">iOS 27 · офлайн-движок сведения</p>
          </div>
          <div className="flex items-center gap-1.5 rounded-full bg-white/8 px-2.5 py-1 text-[11px] text-white/60">
            <span className={`h-1.5 w-1.5 rounded-full ${online ? "bg-emerald-400" : "bg-amber-400"}`} />
            {online ? "онлайн" : "офлайн"} · {tracks.filter((t) => t.analysis).length}/{tracks.length} готово
          </div>
        </header>

        <div className="glass overflow-hidden rounded-3xl px-3 pt-3">
          <Visualizer engine={engine} color={inTransition ? nextC : c1} color2={c2} height={64} />
        </div>

        <NowPlaying
          track={current}
          next={nextTrack}
          snap={snap}
          onToggle={() => void actions.toggle()}
          onNext={() => void actions.next()}
          onPrev={() => void actions.prev()}
          onSeek={actions.seek}
          onMixNow={actions.mixNow}
        />

        <UpNext
          current={current}
          next={nextTrack}
          wave={settings.wave}
          transition={snap?.transition ?? null}
          levels={snap?.levels ?? { A: 0, B: 0 }}
          activeDeck={snap?.activeDeck ?? "A"}
        />

        <MixControls settings={settings} onChange={setSettings} />

        <Library
          tracks={tracks}
          currentId={current?.id ?? null}
          nextId={nextTrack?.id ?? null}
          demoProgress={demoProgress}
          onPlay={actions.play}
          onRemove={actions.remove}
          onAddFiles={actions.addFiles}
          onLoadDemo={actions.loadDemo}
          onSetNext={actions.setNext}
        />

        <footer className="px-2 pt-2 text-center text-[10px] leading-relaxed text-white/30">
          Весь анализ (BPM, фаза сетки, тональность Camelot, энергия, точки микса) и DSP-обработка выполняются на устройстве.
          Добавьте на экран «Домой» — приложение работает без сети.
        </footer>
      </main>
    </div>
  );
}
