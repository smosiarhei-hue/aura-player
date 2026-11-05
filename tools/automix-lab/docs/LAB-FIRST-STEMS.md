# Lab-first stems (не ломать iOS AU)

## Почему

Field Automix (`AUSoundIsolation` → residual vocal) **портил инструментал**:
водянистый bed, артефакты, грязный mashup. Тайминг был ок (1055), звук — нет.

## Правило

1. **Сначала** итерации в `tools/automix-lab` (`vocalInstrumental.ts` Mid/Side **bed**).
2. Слушаем `npm run render:ideal` / live player / `smoke:stems`.
3. Только когда bed/vocal звучат чисто — портим алгоритм в Swift `StemSeparator`.
4. `StemSeparator.useSoundIsolation = false` пока lab не одобрит neural bake.

## Нейро-окно перехода

Яндекс отдаёт только микс. Пока трек играет, `POST /api/stems/window` режет последние ~36 с (аутро) и первые ~36 с (интро) через [StemSplit/demucs-onnx](https://github.com/StemSplit/demucs-onnx). Если оба окна готовы к сведению, плеер ставит вокал A и инструментал B и на посадке возвращает сухой микс B. Mid/Side в `vocalInstrumental.ts` остаётся запасным путём, если окно ещё не готово. На бейдже в этот момент написано HTDemucs.

```bash
pip install demucs-onnx
```

## Lab carve (источник истины)

| Mode | Файл | Поведение |
|------|------|-----------|
| `instrumental` + `bed` | `src/dsp/vocalInstrumental.ts` | soft formant/presence tuck, keep sub+body+sides |
| `instrumental` + `leadKill` | same | nuclear center mute (редко; портит body) |
| `vocal` | same | mid boost + side cut (не dry−AU residual) |

iOS сейчас зеркалит **bed** в `StemSeparator.renderHybridInstrumental`.

## Команды

```bash
cd tools/automix-lab
npm install
npm run dev          # http://127.0.0.1:43187
npm run smoke:stems  # метрики mid tuck / side keep
npm run render:ideal -- --limit 12
```

Слушай `artifacts/sonivo-ideal-automix.mp3` — если инструментал тонкий/водянистый,
крути `processBufferStem` **bed** cuts (`bodyCut` / `formantCut` / `presCut`), не AU.

## Порт в приложение (чеклист)

- [ ] Lab bed amount ~0.55–0.70 звучит на 3+ парах
- [ ] Vocal isolate не шипит и не тащит kick
- [ ] `smoke:stems` green
- [ ] Скопировать коэффициенты в `StemSeparator.renderHybridInstrumental`
- [ ] IPA smoke; только потом пробовать `useSoundIsolation = true` A/B
