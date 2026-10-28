# AutoMix Mashup

## Сопоставление с DJ-практикой

| Приём DJ | Где в Sonivo | Статус |
|---|---|---|
| Equal-power crossfade | `CrossfadeCurve` + live `tickTransition` | Live |
| Bass swap (убрать бас уходящего, ввести бас входящего) | MixPlanner `dropSwap` / `seamlessLoop`; live `MashupLiveEQEnvelope` | Live EQ + DualDeck FX |
| Vocal↔instrumental layering | Live envelope: outgoing vocal hold + incoming instrumental body; then vocal swap | Live EQ |
| Vocal pocket (приглушить вокал входящего до дропа) | `vocalDucking` в плане; live mid/presence duck | Live EQ + DualDeck FX |
| High-pass riser на уходящем | `highPass` FX; live progressive body→mid cut | Live EQ proxy + DualDeck |
| Mid duck / soft reveal | Live mid duck on A + LPF→open on B | Live EQ proxy |
| Low-pass reveal на входящем | `lowPass` FX; live soft air/presence open | Live EQ proxy + DualDeck (V2) |
| Echo-out хвост | `echoOut` FX | DualDeck (V2 runner) |
| Beatmatch / rate ramp | `rateA`/`rateB` + `rateRamp` | DualDeck (V2 runner) |
| Camelot key shift | `pitchShiftCentsB` → `setPitchCents` | DualDeck (V2 runner) |

Источник планов: `Marshal`-style анализ не нужен — архетипы уже в `Packages/AutoMixV2/.../MixPlanner.swift`.
Прототип web mashup: `Sonivo/incoming/src/audio/engine.ts`.

## Что сделано в этом срезе

1. **`MashupTransitionExecutor`** — исполняет полный `TransitionPlan` на протоколе `MashupTransitionAudio` (тики по тактам, EffectAutomation).
2. **`DualDeck.setPitchCents`** + **`MixPlanRealtimeTransitionRunner`** — runner для DualDeck (готов к V2 ownership).
3. **Live PlayerCore** — режим `AutoMix Mashup`: equal-power громкости + расширенный `MashupLiveEQEnvelope` (bass swap, vocal hold↔pocket, HPF riser, mid duck, soft reveal) через per-deck / per-item EQ. Не ломает CI equal-power контракт в `AutoMixDJEngine.computeVolumesAndEQ`.
4. Настройки снова показывают AutoMix Mashup; **слайдер длительности скрыт** в режиме Mashup — длина сведения только из blend-point detection.
5. **`MashupBlendScheduler`** — автодетект blend points: cue по outro (`mixOut`, ≥75% трека), вход B по `mixIn` / intro lead; длина окна = хвост outro / bar ladder, без preferred из UI-слайдера. Live путь берёт `TransitionPlan` / `TrackProfile` из analysis runtime, если есть, иначе structural heuristic.

## Streaming

Yandex / online tracks use dual `AVPlayer` + `StreamBeatTap` (`MTAudioProcessingTap`).
AutoMix Mashup now publishes **per-item EQ overrides** during the transition:

- Outgoing stream item → bass kill / HPF riser / late vocal duck
- Incoming stream item → instrumental body + vocal pocket → bass restore + soft reveal
- Mixed stream↔local uses stream overrides on the AVPlayer side and native `eqOffset*` on the engine side
- Overrides clear on complete/cancel so the next track is clean

Dolby / spatial-passthrough items cannot take PCM EQ (existing StreamBeatTap rule); those fall back to equal-power volumes only.

## Что ещё не включено

- Force-disabled AutoMix V2 / Neuro ownership пока **не** переключали: полный beatmatch + echo на DualDeck ждёт отдельного безопасного включения.
- `tapeStop` / `beatStutter` в planner по-прежнему не выбираются матрицей архетипов.

## Как слушать

Настройки → Переходы → **AutoMix Mashup**. Работает на локальных и стриминговых треках (Yandex). Длительность сведения **автоматическая** (outro/intro / analysis plan) — слайдер «N секунд» относится только к обычному кроссфейду.
