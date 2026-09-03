import { memo } from "react";
import type { MixSettings, MixStyle } from "../types";
import { cn } from "../utils/cn";

interface Props {
  settings: MixSettings;
  onChange: (s: MixSettings) => void;
}

const STYLES: { id: MixStyle; name: string; desc: string }[] = [
  { id: "smooth", name: "Плавный", desc: "Длинный equal-power кроссфейд + мягкий EQ" },
  { id: "club", name: "Клуб", desc: "Резкий обмен басами на «единицу» такта" },
  { id: "echo", name: "Эхо", desc: "Уходящий трек растворяется в delay" },
  { id: "cut", name: "Кат", desc: "Мгновенная склейка по такту" },
];

export default memo(MixControls);

function MixControls({ settings, onChange }: Props) {
  const set = <K extends keyof MixSettings>(k: K, v: MixSettings[K]) => onChange({ ...settings, [k]: v });
  const styleDesc = STYLES.find((s) => s.id === settings.style)?.desc;

  return (
    <section className="glass rounded-3xl p-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-white">AutoMix DSP</h3>
        <span className="rounded-md bg-emerald-500/15 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-emerald-300">офлайн</span>
      </div>

      <div className="mt-3 grid grid-cols-4 gap-1 rounded-xl bg-white/6 p-1">
        {STYLES.map((s) => (
          <button
            key={s.id}
            onClick={() => set("style", s.id)}
            className={cn(
              "rounded-lg py-1.5 text-xs font-medium transition",
              settings.style === s.id ? "bg-white/15 text-white shadow" : "text-white/50 hover:text-white/80",
            )}
          >
            {s.name}
          </button>
        ))}
      </div>
      <p className="mt-1.5 px-1 text-[11px] text-white/40">{styleDesc}</p>

      <div className={cn("mt-3", (settings.style === "cut" || settings.style === "echo") && "opacity-40 pointer-events-none")}>
        <div className="flex items-center justify-between text-xs text-white/60">
          <span>Длина перехода</span>
          <span className="font-mono text-white">{settings.lengthBeats} бит · {settings.lengthBeats / 4} такт.</span>
        </div>
        <input
          type="range"
          min={4}
          max={64}
          step={4}
          value={settings.lengthBeats}
          onChange={(e) => set("lengthBeats", Number(e.target.value))}
          className="range mt-1 w-full"
        />
      </div>

      <div className="mt-3 grid grid-cols-2 gap-2">
        <Toggle label="Моя волна" hint="автоподбор по вайбу" on={settings.wave} onClick={() => set("wave", !settings.wave)} accent />
        <Toggle label="Beatmatch" hint="подгон темпа ±8%" on={settings.beatmatch} onClick={() => set("beatmatch", !settings.beatmatch)} />
        <Toggle label="Тональность" hint="Camelot-совместимость" on={settings.keyMatch} onClick={() => set("keyMatch", !settings.keyMatch)} />
        <Toggle label="EQ-swap" hint="обмен басами" on={settings.eqSwap} onClick={() => set("eqSwap", !settings.eqSwap)} />
        <Toggle label="Автогейн" hint="выравнивание громкости" on={settings.autoGain} onClick={() => set("autoGain", !settings.autoGain)} />
      </div>
    </section>
  );
}

function Toggle({ label, hint, on, onClick, accent }: { label: string; hint: string; on: boolean; onClick: () => void; accent?: boolean }) {
  return (
    <button
      onClick={onClick}
      className={cn(
        "flex items-center justify-between rounded-xl px-3 py-2 text-left transition active:scale-[0.98]",
        on ? (accent ? "bg-gradient-to-r from-fuchsia-500/30 to-indigo-500/30 ring-1 ring-fuchsia-400/40" : "bg-white/12") : "bg-white/5",
      )}
    >
      <div>
        <div className="text-xs font-semibold text-white">{label}</div>
        <div className="text-[10px] text-white/40">{hint}</div>
      </div>
      <div className={cn("relative h-5 w-9 shrink-0 rounded-full transition", on ? "bg-emerald-400" : "bg-white/15")}>
        <div className={cn("absolute top-0.5 h-4 w-4 rounded-full bg-white shadow transition-all", on ? "left-4.5" : "left-0.5")} />
      </div>
    </button>
  );
}
