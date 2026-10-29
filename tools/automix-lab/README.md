# Automix Lab · Modern Mashup

Локальный стенд: AI разбирает пару треков и сводит **окно автомикса** как современный
мэшап — инструментал A × вокал/грув B, один бас, фраза 8/16 тактов. Не radio-crossfade.

## Запуск

```bash
cd tools/automix-lab
npm install
npm run dev
```

Открой [http://127.0.0.1:43187](http://127.0.0.1:43187).

Макет iPhone: [http://127.0.0.1:43187/iphone.html](http://127.0.0.1:43187/iphone.html).

## Modern mashup craft (`modernMashup.ts`)

| Режим | Когда | Что слышно |
|---|---|---|
| **Acapella Drop** | A outro уже инструментал, B с вокалом | B vocal сразу поверх A bed + sidechain |
| **Vocal Swap** | оба ещё поют | Carve A → B groove → B vocal на mashup-пике × A instr |
| **Texture Bed** | A поёт, B инструментал | Мягкий carve A × bed B |
| **Instrumental Wash** | оба beds | Фильтры / текстура |

ONE VOCAL: никогда два лида сразу. Но B vocal открывается на **mashup peak**
(когда A уже bed), а не только на LAND — иначе мэшапа не слышно.

## DSP toolkit (`src/dsp/`)

| Модуль | Что делает |
|---|---|
| `vocalInstrumental.ts` | Multiband Mid/Side bake; `bakeInstrThenDry`; `applySidechainDuck` |
| `bassEq.ts` | Bass kill/on, mid pocket, air |
| `filters.ts` | HPF riser / LPF reveal |
| `echo.ts` | Tempo-sync echo-out |
| `stemEnvelopes.ts` | Огибающие stem/FX по актам |

Цепь деки:

```
source → MidSideStem → BassEq → HPF/LPF → EchoOut → Gain → master
```

Offline bake режет **только окно** сведения (не весь трек), затем dual-deck play.

## AI пайплайн

1. Анализ A/B — BPM, Key/Camelot, vocal, mixIn/Out  
2. Transition Planner §2.4 — EQ Blend / Filter / Echo / Long / Cut / Smart  
3. `chooseModernMashup` + `planAutomix` — craft + DSP recipe  
4. Offline bake стемов + sidechain A under B  
5. Play LOCK → INVITE → ONE BASS → **MASHUP** → LAND  

## DJ 5 актов

`LOCK` → `INVITE B` / `ACAPELLA` → `ONE BASS` / `VOCAL SWAP` → `MASHUP` → `LAND`  
(см. `src/audio/djCraft.ts`)

## Связь с Sonivo iOS

| Lab | iOS |
|---|---|
| `analyzeTrackBuffer` | `TrackAnalyzer` |
| `modernMashup` + `planAutomix` | `MixPlanner` + `MashupLiveStyle` |
| stem bake + sidechain | `MidSideStemBaker` (master CAF) |
| Play mashup | PlayerCore AutoMix Mashup |

## Ограничения

- Mid/Side ≠ Demucs stems (клубный karaoke-трюк)
- Rate «виниловый» (темп+питч)
- Файлы только локально в браузере
