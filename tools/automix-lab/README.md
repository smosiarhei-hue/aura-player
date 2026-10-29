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

## Что делает AI

На каждый файл: BPM, energy, vocal proxy, mixOut/mixIn.  
По паре (`planAutomix`): beatmatch, cues на тактах, 8/16 bars, архетип, one-bass + dual-layer.

**✦ AI Auto Mix** — полный автопайплайн:

1. анализ A/B (BPM, vocal, mixIn/Out)  
2. `planAutomix` решает стемы / bass / HPF / echo  
3. **offline bake** Mid/Side instrumental A + vocal B  
4. play dual-deck с live FX поверх bake  

Список решений появляется под транспортом.

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
