# AutoMix Mashup

## Что это

Не «просто эффекты» и не обычный кроссфейд. Live AutoMix Mashup **сводит два трека**:

1. Анализирует пару (BPM / сетка / mixIn·mixOut / дропы / Camelot).
2. **Accel → tempo lock → decel** — оба дека разгоняются в общий BPM, держат сетку, затем плавно возвращаются к 1.0.
3. **Key shift** — входящий трек подтягивается по тональности (cents) на native decks.
4. Стартует B с `bInStartSec` (intro / pre-drop), A — с outro cue.
5. Кладет **инструментал B под вокал A**, затем handoff: бас B + вокал B, A уходит.
6. Архетип задаёт filter sweeps (dropSwap / seamlessLoop / echoFreeze / energyWash / tapeStop).

## Алгоритм под каждую пару

| Шаг | Где |
|---|---|
| Анализ current/next (в т.ч. download при Mashup) | `AutoMixV2AnalysisRuntime` |
| Архетип + tempoMatch | `MixPlanner` / `BeatGridSynchronization` |
| rate ramp, pitch, handoff, vocal bed | `MashupLiveStyle.resolve` |
| Cue / длина окна | `MashupBlendScheduler` |
| Live volumes + EQ + rates | `PlayerCore.tickTransition` |
| Архетипные EQ-свипы | `MashupLiveEQEnvelope` |

Бейджи: `TEMPO LOCK` → `KEY SHIFT` → `BEATMATCH` → `BASS SWAP` → `VOCAL × INSTR` → `HANDOFF` → `VOCAL POCKET` → `SOFT REVEAL` → `TEMPO SETTLE`.

Пока BPM ещё не посчитан (холодный старт / нет файла), style без beatmatch (`rate=1`) и reason `Waiting for BPM analysis` — после анализа следующей пары включается настоящий lock.

## DualDeck V2

Полный echo / DualDeck ownership по-прежнему force-disabled. Live путь уже делает beatmatch + accel/decel + vocal↔instrumental на AVAudioEngine / AVPlayer. Camelot pitch на стриме ограничен (AVPlayer rate без независимого pitch); на локальных треках — полный `AVAudioUnitTimePitch`.

## Как слушать

Настройки → Переходы → **AutoMix Mashup**. Слайдер длительности только у кроссфейда; mashup сам выбирает окно по outro/intro и плану.
