# AutoMix Mashup

## Что это

Не «просто эффекты». Live AutoMix Mashup **сводит два трека**:

1. Анализирует пару (BPM / сетка / mixIn·mixOut / дропы).
2. **Beatmatch** — держит `rateA` / `rateB` к общему tempo на всём окне сведения.
3. Стартует B с `bInStartSec` (intro / pre-drop), A — с outro cue.
4. Кладет **инструментал B под вокал A**, затем handoff: бас B + вокал B, A уходит.

## Алгоритм под каждую пару

| Шаг | Где |
|---|---|
| Анализ current/next (в т.ч. download при Mashup) | `AutoMixV2AnalysisRuntime` |
| Архетип + tempoMatch | `MixPlanner` / `BeatGridSynchronization` |
| rateA/rateB, handoff, vocal bed | `MashupLiveStyle.resolve` |
| Cue / длина окна | `MashupBlendScheduler` |
| Live volumes + EQ + rates | `PlayerCore.tickTransition` |

Бейджи: `BEATMATCH xxx` → `BASS SWAP` → `VOCAL × INSTR` → `HANDOFF` → `VOCAL POCKET` → `SOFT REVEAL`.

Пока BPM ещё не посчитан (холодный старт / нет файла), style без beatmatch (`rate=1`) и reason `Waiting for BPM analysis` — после анализа следующей пары включается настоящий lock.

## DualDeck V2

Полный echo / DualDeck ownership по-прежнему force-disabled. Live путь уже делает beatmatch + vocal↔instrumental на AVAudioEngine / AVPlayer.

## Как слушать

Настройки → Переходы → **AutoMix Mashup**. Слайдер длительности только у кроссфейда; mashup сам выбирает окно по outro/intro и плану.
