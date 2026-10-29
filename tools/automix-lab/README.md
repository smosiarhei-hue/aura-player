# Automix Lab · AI + DSP Toolkit

Локальный стенд: AI разбирает треки и сводит пару как Apple Music Automix.
DSP-инструменты написаны с нуля на Web Audio (не только volume/EQ envelopes).

## Запуск

```bash
cd tools/automix-lab
npm install
npm run dev
```

Открой [http://127.0.0.1:43187](http://127.0.0.1:43187).

Макет приложения на iPhone 17 Pro: [http://127.0.0.1:43187/iphone.html](http://127.0.0.1:43187/iphone.html) —
плеер с Автомикс, DSP-инструменты (вокал/инструментал, HPF, echo) и ручная настройка.

## DSP toolkit (`src/dsp/`)

| Модуль | Что делает |
|---|---|
| `vocalInstrumental.ts` | Mid/Side: удаление вокала (instrumentalize) / фокус вокала (vocalize); offline `processBufferStem` |
| `bassEq.ts` | Bass kill/on (lowshelf), mid vocal pocket, air shelf |
| `filters.ts` | HPF riser на уходящем, LPF reveal на входящем |
| `echo.ts` | Tempo-sync echo-out (0.75 beat delay + feedback LPF) |
| `stemEnvelopes.ts` | Огибающие stem/FX по DJ-актам LOCK→LAND |

Цепь каждой деки:

```
source → MidSideStem → BassEq → HPF/LPF → EchoOut → Gain → master
```

Preview-кнопки в UI: **Preview A instrumental** / **Preview B vocal** — offline Mid/Side render.

## Что делает AI (ТЗ AutoMix / Intelligent Transitions)

На каждый файл: BPM, **Key → Camelot** (chroma + Krumhansl), energy, vocal proxy, mixOut/mixIn.  
По паре (`planAutomix` + `transitionPlanner` §2.4):

| Условие | Тип |
|---|---|
| BPM Δ > 8% и ключи несовместимы | Echo Out / Cut on the 1 |
| Ключи совместимы + BPM близки | EQ Blend / Long Blend |
| Высокий energy shift | Filter Sweep |
| Короткий outro | Echo Out |
| Иначе | Smart Crossfade |

Плюс: beatmatch (если viable), Camelot pitch ±200¢, cues на тактах, one-vocal rule, one-bass.

**✦ AI Auto Mix** — полный автопайплайн:

1. анализ A/B (BPM, Key/Camelot, vocal, mixIn/Out)  
2. Transition Planner выбирает тип §2.4  
3. `planAutomix` → DSP recipe (стемы / bass / HPF / echo / cut)  
4. **offline bake** Mid/Side + dual-deck play  

В UI: бейдж `TZ · <тип> · KeyA → KeyB` и список решений под транспортом.

## DJ 5 актов

`LOCK` → `INVITE B` → `ONE BASS` → `MASHUP` → `LAND`  
(см. `src/audio/djCraft.ts`)

## Связь с Sonivo iOS

| Lab | iOS |
|---|---|
| `analyzeTrackBuffer` | `TrackAnalyzer` |
| `planAutomix` | `MixPlanner` + `MashupLiveStyle.resolve` |
| DSP chain | DualDeck FX + `MashupLiveEQEnvelope` |
| Play mashup | PlayerCore AutoMix Mashup |

## Ограничения

- Mid/Side ≠ Demucs stems (клубный karaoke-трюк, слышимо и полезно)
- Rate «виниловый» (темп+питч)
- Файлы только локально в браузере
