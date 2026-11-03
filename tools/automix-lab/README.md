# Sonivo Automix · Player + Lab

Полноценный Now Playing плеер (iOS 27 Liquid Glass) с **DJ mashup** через API Яндекс Музыки («Моя волна»).

- Ambient обложка + Dynamic Island фаз Automix
- Gaze-параллакс на артворке, spring-транспорт
- **Automix choreography** (Premium motion): shared-element cover A→B, kinetic title, island morph LOCK→LAND
- Sheets: Текст (караоке), Очередь, Coach/Premium, Яндекс auth
- Motion skills in repo: `.agents/skills/motion-design`, `.agents/skills/anim` (Emil Kowalski / LottieFiles)

Mashup ≠ кроссфейд. Это короткая DJ-история на стыке треков:

| Акт | Что слышно |
|---|---|
| **LOCK** | Темп уже общий |
| **INVITE B** | B входит гостем |
| **ONE BASS** | Пол отдаёт один бас |
| **MASHUP** | Outro A (bed) × вокал/грув B — ощущение ремикса |
| **LAND** | Уже песня B |

Правило **ONE VOCAL**: dual mashup только если outro A уже инструментал. Иначе **Safe Exit** (Cut / Echo) — без двух лидов.

## Запуск

```bash
cd tools/automix-lab
npm install
npm run dev
```

- **Плеер (главный):** [http://127.0.0.1:43187](http://127.0.0.1:43187)
- DSP Lab: [http://127.0.0.1:43187/lab.html](http://127.0.0.1:43187/lab.html)
- iPhone 17 Pro Cosmic Orange (живой экран): [http://127.0.0.1:43187/iphone.html](http://127.0.0.1:43187/iphone.html)

## Как слушать

1. **Подключить** Яндекс (Device Flow → браузер → код).
2. **Play** — сразу играет трек A (download+decode). Пока идёт песня, **Automix brain** в фоне:
   анализ BPM/key/energy, LRC/Whisper, загрузка B, neural cue → план mashup и retarget AM-маркера.
3. Фазы на Dynamic Island; режим пары — Acapella Drop / Safe Exit / …

Токен: `.ym-token.json` (gitignored). Кэш: `.ym-cache/`.

### Почему не FLAC, а HQ 192

Код **запрашивает** lossless (`/get-file-info?quality=lossless`). Plus на аккаунте есть — но Яндекс **сам решает**, что выдать. С IP датацентра вне РФ/РБ (например cloud-агент в AWS US) ответ стабильно:

`quality: "nq"`, `codec: "aac-mp4"`, `bitrate: 192`

Тогда мы честно падаем на max `download-info` (часто тоже 192) и пишем причину в бейдж (tooltip) и `/api/ym/status` → `lossless`.

Чтобы получить FLAC:

1. Запусти lab **локально** из Беларуси/РФ, или
2. Поставь `YM_PROXY=http://user:pass@ru-proxy:port` (HTTP(S) proxy с IP РФ/РБ) перед `npm run dev`.

## Song Transitions (как Apple Music AutoMix)

В **Очередь** — переключатель **AutoMix | Duet | Crossfade | Off**:

| Режим | Поведение |
|---|---|
| **AutoMix** | Beatmatch + mashup craft; при сбое плана — Crossfade fallback |
| **Duet** | Full-stack Adaptive Duet: слушает vocal/energy/LRC, выбирает **bars/beats**, beatmatch+stretch, Camelot pitch, soft Mid/Side carve A, LPF invite / HPF+echo LAND, ONE BASS/kick, B-led dual → LAND (без nuclear bake) |
| **Crossfade** | Equal-power 1–12 с, без stems/FX |
| **Off** | Без overlap → следующий трек |

Во время сведения на island: **Mixing** (shimmer), covers A→B morph.

Спека по публичным источникам Apple: `docs/APPLE-AUTOMIX-SPEC.md` (WWDC 2025 / iOS **26** — не «27»).

## Premium AutoMix (всегда on)

Платный стек, который реально работает — автоматизирован целиком:

| Функция | Что делает |
|---|---|
| **HQ / Lossless** | FLAC через `/get-file-info`; если API отдал nq/192 — geo (см. ниже) |
| **Моя волна** | Rotor + feedback started/finished/skip |
| **BPM + Camelot** | Beatmatch + harmonic pitch ±200¢ |
| **Фраза 8/16** | Окно на сетке тактов |
| **TZ §2.4** | EQ / Filter / Echo / Long / Cut / Smart |
| **ONE BASS** | Бас A → B на доле |
| **ONE VOCAL / Safe Exit** | Dual mashup только при instrumental outro A |
| **Mix Critic** | Vocal Safe + Bass Surgeon |
| **Premium LAND** | Bar-snap handoff · HPF exit · echo ring · rate/pitch → natural · A→0 · B home |
| **Prefetch** | Next качается во время PLAY |

LAND — не «конец фейда». Это акт, где B уже дома, A выходит чисто.

## Архитектура

| Слой | Файлы |
|---|---|
| Плеер UI | `src/player.ts` |
| Радио-цикл | `src/audio/waveRadio.ts` |
| Premium LAND | `src/audio/premiumAutomix.ts` |
| Dual-deck DSP | `src/audio/engine.ts` + `src/dsp/*` |
| Craft / план | `modernMashup.ts`, `aiMixEngine.ts`, `transitionPlanner.ts` |
| Yandex API | `server/yandexLab.ts` (`@dvxch/yandex-music`, `user:onyourwave`) |

## Текст · караоке + Automix cue

- Трек играет **с начала** (mixIn), mashup — фраза ~8–16 тактов (не прыжок в outro).
- На таймлайне маркер **AM** — точка Automix; скраббер только до него.
- Текст: сначала **LRC Яндекса** (`/api/ym/lyrics/:id`), иначе офлайн
  **Whisper tiny** (`.whisper-cache/`). Строки и слова едут с часами плеера.
- Whisper/LRC brain слушает **A и B**: mixOut на конце фразы, mixIn на входе следующего.
- Окно mashup 12–16 тактов с equal-power ride — без дыр по громкости и басу на LAND.

```bash
# API
GET  /api/ym/lyrics/:id
POST /api/whisper/transcribe  { trackId, fileName?, lrc? }
GET  /api/whisper/transcript/:id
GET  /api/whisper/status
```

## Transition Coach (обучающий лог)

Инструмент: каждый live-mashup пишется в `.mix-log.jsonl`, скорится гейтами
(ONE VOCAL / ONE BASS / LAND…). Если провал — offsets в `.mix-coach.json`
чуть сдвигаются; следующий план их применяет.

```bash
# offline train на живой Моей волне (нужен логин)
npm run train:coach -- --rounds 8

# API
# GET  /api/mix/coach
# GET  /api/mix/log?limit=12
# POST /api/mix/log  { report, pair, learn:true }
```

В плеере блок **Transition Coach · realtime** показывает последний score.

## Ideal Automix export (HQ MP3)

Offline: score cached `.ym-cache` pairs (coach + critic + neural cues), render
the winner with stem bake + continuity ride, write lossless WAV + **320 kbps MP3**.

```bash
npm run render:ideal -- --limit 28
# → artifacts/sonivo-ideal-automix.{wav,mp3,json}
```

## Lab-first stems (важно)

**Не крути AU / жёсткий vocal-cut в iOS, пока lab не ок.**  
AUSoundIsolation в поле портил инструментал. Источник истины — Mid/Side **bed** в
`src/dsp/vocalInstrumental.ts`. Спека: `docs/LAB-FIRST-STEMS.md`.

```bash
npm run smoke:stems          # mid tuck / side keep
npm run render:ideal -- --limit 12
# слушай artifacts/sonivo-ideal-automix.mp3
```

В приложении `StemSeparator.useSoundIsolation = false` до явного A/B после порта.

## Smokes

```bash
npm run smoke:mashup
npm run smoke:smooth
npm run smoke:critic
npm run smoke:tz
npm run smoke:land
npm run smoke:coach
npm run smoke:transcript
npm run smoke:stems
```
