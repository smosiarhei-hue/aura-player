# AutoMix Mashup

## Сопоставление с DJ-практикой

| Приём DJ | Где в Sonivo | Статус |
|---|---|---|
| Per-pair algorithmic plan | `MixPlanner` + `MashupLiveStyle.resolve` | Live |
| Asymmetric vocal↔instrumental volumes | `MashupLiveStyle.volumes` (не equal-power) | Live |
| Bass swap | MixPlanner `dropSwap` / live EQ | Live EQ + DualDeck FX |
| Vocal↔instrumental layering | Outgoing vocal hold + incoming instrumental bed → vocal swap | Live EQ |
| Vocal pocket | `vocalDucking` / live presence duck | Live EQ + DualDeck FX |
| High-pass riser | `highPass` / live body→mid cut | Live EQ proxy + DualDeck |
| Mid duck / soft reveal | Live mid duck on A + LPF→open on B | Live EQ proxy |
| Rate / pitch micro-moves | Native `AVAudioUnitTimePitch` + stream rate | Live |
| Echo-out / full beatmatch | DualDeck executor | DualDeck (V2 runner) |

Источник планов: `Packages/AutoMixV2/.../MixPlanner.swift`.
Прототип web mashup: `Sonivo/incoming/src/audio/engine.ts`.

## Алгоритм под каждую пару

1. **`AutoMixV2AnalysisRuntime`** крутится и при live **AutoMix Mashup** (не только при V2 ownership): профилирует current/next, если есть локальный/кэш файл.
2. **`MixPlanner.plan`** выбирает архетип (`dropSwap`, `seamlessLoop`, `echoFreeze`, `energyWash`, …) по BPM/ключу/сетке.
3. **`MashupLiveStyle.resolve`** превращает план/профили (или duration-heuristic) в тайминги: bass swap, vocal hold, vocal pocket, асимметричные громкости, глубины EQ, лёгкий rate/pitch.
4. **`MashupBlendScheduler`** задаёт cue (`mixOut` ≥75%) и длину окна по outro/intro — **слайдер длительности скрыт**.
5. Live `tickTransition` применяет style volumes + `MashupLiveEQEnvelope(style:)` + micro time-pitch.

Equal-power контракт в `AutoMixDJEngine.computeVolumesAndEQ` **не трогаем** (CI). Обычный кроссфейд по-прежнему на `CrossfadeCurve`.

## Streaming

Yandex / dual `AVPlayer` + `StreamBeatTap`:
- per-item EQ overrides по style envelope
- асимметричные volume curves + лёгкий rate
- без полного download для анализа в mashup-only (только cache/local); V2 ownership по-прежнему может качать

## Как слушать

Настройки → Переходы → **AutoMix Mashup**. Длительность сведения **автоматическая** под каждую пару; слайдер «N секунд» только у обычного кроссфейда.
