# Automix Lab · AI Engine

Локальный стенд + **AI-движок**, который сам обрабатывает каждый трек и сводит пару как Apple Music Automix.

## Запуск на своём компьютере

```bash
cd tools/automix-lab
npm install
npm run dev
```

Открой [http://127.0.0.1:43187](http://127.0.0.1:43187).

## Что делает AI

На каждый загруженный файл:

1. **BPM** — автокорреляция onset-огибающей (70–180, fold в 80–160)
2. **Energy / vocal proxy** — кривые по треку
3. **mixOut** — outro / инструментальный хвост (после 75% трека)
4. **mixIn** — вход после тихого intro, ближе к биту/вокалу

По паре (`planAutomix`):

- beatmatch rates к общему BPM  
- cues на сетке тактов  
- окно 8/16 баров из outro  
- архетип `dropSwap` / `seamlessLoop` / `energyWash`  
- бас от B, dual-layer громкости (мэшап A+B)

Один клик **✦ AI Auto Mix** — анализ (если ещё нет) → план → play.

## Ручная доводка

После AI можно крутить rates / bass / handoff и **Export JSON**.  
Поля ≈ iOS `MashupLiveStyle` + cues из `MashupBlendScheduler`.

## Связь с Sonivo iOS

В приложении тот же смысл уже встроен:

| Lab AI | iOS |
|---|---|
| `analyzeTrackBuffer` | `TrackAnalyzer` / `TrackAnalysisComputer` |
| `planAutomix` | `MixPlanner` + `MashupLiveStyle.resolve` |
| Play mashup | `PlayerCore` AutoMix Mashup |

Включи **Настройки → Переходы → AutoMix Mashup** — телефон сам анализирует current/next и сводит.

## Ограничения

- Rate «виниловый» (темп+питч), без отдельного time-stretch как `AVAudioUnitTimePitch`
- Camelot key в lab пока 0 (полная гармоника — в iOS профилях)
- Файлы только локально в браузере
