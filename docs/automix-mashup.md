# AutoMix Mashup

## Логика (как Apple Automix)

Не кроссфейд. На стыке **два трека играют вместе** на одной сетке:

1. **BPM / такт** — оба дека на общем tempo (`rateA`/`rateB`), cue A/B на downbeat, чтобы кик следующего попал в фазу.
2. **Бас от следующего** — низ A режется рано (`BASS LOCK`); kick/bass B держат грув.
3. **Мэшап-слой** — outro A как инструментал + уже идущий B с **вокалом и инструменталом**. Оба слышны, не «тихая подложка».
4. После handoff A уходит, B остаётся на натуральном tempo/key.

## Алгоритм под каждую пару

| Шаг | Где |
|---|---|
| Анализ current/next | `AutoMixV2AnalysisRuntime` |
| Tempo match + downbeat cues | `BeatGridSynchronization` / `MashupBlendScheduler` |
| Rate accel→lock→decel, pitch, dual volumes | `MashupLiveStyle` |
| Bass lock + mashup EQ | `MashupLiveEQEnvelope` |
| Live tick | `PlayerCore.tickTransition` |

Бейджи: `TEMPO LOCK` → `KEY SHIFT` → `BEATMATCH` → `BASS LOCK` → `MASHUP` → `HANDOFF` → `VOCAL × INSTR` → `SOFT REVEAL` → `TEMPO SETTLE`.

Пока BPM не посчитан — style без beatmatch (`rate=1`), reason `Waiting for BPM analysis`.

## DualDeck V2

Ownership force-disabled. Live путь: beatmatch + bass-from-B + dual-layer mashup на AVAudioEngine / AVPlayer. Camelot pitch на стриме ограничен; на локальных — полный `AVAudioUnitTimePitch`.

## Как слушать

Настройки → Переходы → **AutoMix Mashup**. Длительность окна — из outro/intro и плана, не из слайдера.
