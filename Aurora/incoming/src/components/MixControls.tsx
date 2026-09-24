import { memo, useState } from "react";
import type { MixSettings, MixStyle } from "../types";
import { cn } from "../utils/cn";

interface Props {
  settings: MixSettings;
  onChange: (s: MixSettings) => void;
}

const STYLES: { id: MixStyle; name: string; desc: string }[] = [
  { id: "mashup", name: "⚡ AutoMix", desc: "Длинное бесшовное сведение 8-16 тактов: непрерывный бит, обмен баса и плавное перетекание" },
  { id: "smooth", name: "🎵 Spotify Flow", desc: "Золотой стандарт Spotify: непрерывный бит-хандофф без проседания энергии" },
  { id: "club", name: "🎛 Клубный", desc: "Сведение с обменом бочки и баса на 8 тактов (Pioneer DJ Kick-Swap)" },
  { id: "echo", name: "🌌 Эхо-Флоу", desc: "Уходящий трек мягко растворяется в ритмичном дилее поверх нового бита" },
  { id: "cut", name: "✂ Кат", desc: "Мгновенная склейка по сильной доле такта" },
];

export default memo(MixControls);

function MixControls({ settings, onChange }: Props) {
  const [showSwift, setShowSwift] = useState(false);
  const set = <K extends keyof MixSettings>(k: K, v: MixSettings[K]) => onChange({ ...settings, [k]: v });
  const styleDesc = STYLES.find((s) => s.id === settings.style)?.desc;

  return (
    <section className="glass rounded-3xl p-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-white">AutoMix V2 DSP</h3>
        <span className="rounded-md bg-emerald-500/20 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-emerald-300">Harmonic Flow</span>
      </div>

      <div className="mt-3 grid grid-cols-5 gap-1 rounded-xl bg-white/6 p-1">
        {STYLES.map((s) => (
          <button
            key={s.id}
            onClick={() => set("style", s.id)}
            className={cn(
              "rounded-lg py-1.5 text-[11px] font-medium transition text-center px-0.5",
              settings.style === s.id ? "bg-white/15 text-white shadow ring-1 ring-white/10" : "text-white/50 hover:text-white/80",
            )}
          >
            {s.name}
          </button>
        ))}
      </div>
      <p className="mt-1.5 px-1 text-[11px] text-fuchsia-300/80 font-medium">{styleDesc}</p>

      <div className={cn("mt-3 rounded-2xl bg-white/5 p-3 border border-white/5", settings.style === "cut" && "opacity-40 pointer-events-none")}>
        <div className="flex items-center justify-between text-xs">
          <div className="flex items-center gap-1.5 font-semibold text-white/90">
            <span>Длина перехода</span>
            {settings.autoLength && (
              <span className="rounded-full bg-gradient-to-r from-fuchsia-500/25 to-indigo-500/25 border border-fuchsia-400/40 px-2 py-0.5 text-[10px] font-semibold text-fuchsia-200">
                ✨ ИИ подбор по тактам
              </span>
            )}
          </div>
          <button
            onClick={() => set("autoLength", !settings.autoLength)}
            className="text-[11px] font-medium text-fuchsia-300 hover:text-fuchsia-200 transition underline underline-offset-2"
          >
            {settings.autoLength ? "Ручной ползунок" : "Включить авто-ИИ"}
          </button>
        </div>

        {settings.autoLength ? (
          <div className="mt-2 flex items-center justify-between rounded-xl bg-fuchsia-950/30 border border-fuchsia-500/20 px-3 py-2 text-xs">
            <span className="text-white/80">
              {settings.style === "smooth"
                ? "8 тактов (32 бита · ~15 сек) — Beat-Handoff без проседания энергии"
                : settings.style === "cut"
                ? "1 такт (4 бита) — мгновенная склейка на сильную долю"
                : settings.style === "club"
                ? "8 тактов (32 бита) — обмен бочки и баса на сильную долю"
                : settings.style === "echo"
                ? "8 тактов — растворение в ритмичном дилее"
                : "8-16 тактов (32-64 бита · ~16-30 сек) — длинный бесшовный AutoMix"}
            </span>
            <span className="font-mono text-fuchsia-300 font-semibold text-[11px] shrink-0 ml-2">Фраза 4/4</span>
          </div>
        ) : (
          <div className="mt-2">
            <div className="flex items-center justify-between text-[11px] text-white/60 mb-1">
              <span>Ручная длина:</span>
              <span className="font-mono text-white font-semibold">{settings.lengthBeats} бит · {settings.lengthBeats / 4} такт.</span>
            </div>
            <input
              type="range"
              min={4}
              max={64}
              step={4}
              value={settings.lengthBeats}
              onChange={(e) => set("lengthBeats", Number(e.target.value))}
              className="range w-full"
            />
          </div>
        )}
      </div>

      <div className="mt-3 grid grid-cols-2 gap-2">
        <Toggle label="Моя волна" hint="автоподбор по вайбу" on={settings.wave} onClick={() => set("wave", !settings.wave)} accent />
        <Toggle label="ИИ Авто-длина" hint="такты/доли/фразы" on={settings.autoLength} onClick={() => set("autoLength", !settings.autoLength)} accent />
        <Toggle label="Beatmatch" hint="авто-лок сетки до ±35%" on={settings.beatmatch} onClick={() => set("beatmatch", !settings.beatmatch)} />
        <Toggle label="Smart Cues" hint="ИИ поиск дропа/входа" on={settings.smartCues} onClick={() => set("smartCues", !settings.smartCues)} accent />
        <Toggle label="EQ-Swap Drop" hint="взрывной обмен басами" on={settings.eqSwap} onClick={() => set("eqSwap", !settings.eqSwap)} />
        <Toggle label="Riser Свип" hint="резонансный разгон HPF" on={settings.riserEffect} onClick={() => set("riserEffect", !settings.riserEffect)} />
        <Toggle label="Beat Stutter" hint="заикание перед дропом" on={settings.beatRoll} onClick={() => set("beatRoll", !settings.beatRoll)} />
        <Toggle label="Тональность" hint="Camelot-совместимость" on={settings.keyMatch} onClick={() => set("keyMatch", !settings.keyMatch)} />
        <Toggle label="Автогейн" hint="выравнивание громкости" on={settings.autoGain} onClick={() => set("autoGain", !settings.autoGain)} />
      </div>

      <div className="mt-4 pt-3 border-t border-white/10">
        <button
          onClick={() => setShowSwift(!showSwift)}
          className="w-full flex items-center justify-between text-xs text-amber-300 font-semibold py-1 hover:text-amber-200 transition"
        >
          <span>📋 Конфигурация для Swift (AutoMix V2)</span>
          <span className="text-[10px] font-mono opacity-60">{showSwift ? "Скрыть ▲" : "Показать ▼"}</span>
        </button>
        {showSwift && (
          <div className="mt-2 rounded-xl bg-black/40 p-3 font-mono text-[11px] text-white/80 border border-white/10 space-y-2">
            <div className="text-[10px] text-amber-400 font-bold uppercase">// MixPlanner.swift / MixSettings</div>
            <pre className="overflow-x-auto text-[10px] text-emerald-300">
{`let settings = MixSettings(
    mode: .automix,
    crossfadeSeconds: ${settings.autoLength ? 0 : (settings.lengthBeats * 0.5).toFixed(1)}, // ${settings.autoLength ? "ИИ-автоподбор по фразам (8-16 тактов)" : `${settings.lengthBeats} бит (${settings.lengthBeats / 4} тактов)`}
    skipTransitionsWithinAlbum: false,
    dontCutEndings: false,
    loudnessNormalization: ${settings.autoGain},
    targetLUFS: -14
)`}
            </pre>
            <div className="text-[10px] text-amber-400 font-bold uppercase pt-1">// FxEvents (AutoMix Stage 4)</div>
            <pre className="overflow-x-auto text-[10px] text-cyan-300">
{`// Режим: ${settings.style.toUpperCase()}
// Сетка: 4/4 такт, выравнивание по Downbeat
// Delay Spillover: 2.8с сохранение хвоста`}
            </pre>
          </div>
        )}
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
