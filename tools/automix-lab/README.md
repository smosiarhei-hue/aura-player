# Automix Lab

Локальный стенд для разработки Sonivo **AutoMix Mashup** на твоём компьютере.

Загружаешь два трека → слушаешь сведение → крутишь ручки (BPM/rates, cues, bass lock, handoff, громкости) → экспортируешь JSON-пресет.

Кривые объёма / баса / rate совпадают по смыслу с live `MashupLiveStyle` в приложении.

## Запуск

```bash
cd tools/automix-lab
npm install
npm run dev
```

Открой [http://127.0.0.1:43187](http://127.0.0.1:43187).

Сборка: `npm run build` → `dist/`.

## Как пользоваться

1. **Deck A** — текущий трек (outro / инструментал).
2. **Deck B** — следующий (уже с вокалом + битом).
3. Введи **BPM** обоих и нажми **Match BPM → rates**.
4. Поставь **Cue A** в конец песни, **Cue B** туда, где следующий уже «играет».
5. **Play mashup** — оба слоя на общей сетке; на handoff шкала снэпается на B.
6. Крути ручки на слух. **Export JSON** — пресет в буфер / textarea.

### Solo

**Solo A/B от cue** — проверить точку входа без сведения.

## Ограничения браузера

- Rate = «виниловый» beatmatch (темп вместе с питчем), как у классического DJ. Независимый time-stretch как у `AVAudioUnitTimePitch` в iOS здесь не эмулируется.
- Автодетект BPM нет — вводи вручную (или с анализатора).
- Файлы остаются локально в браузере, никуда не загружаются.

## Связь с iOS

Поля пресета ≈ `MashupLiveStyle` + cues из `MashupBlendScheduler`:

| Lab | iOS |
|---|---|
| `rateA` / `rateB` | `MashupLiveStyle.rateA/B` |
| `pitchCentsB` | `pitchCentsB` |
| `bassSwapAt` / `handoffAt` | те же |
| `cueASec` / `cueBSec` | outgoing cue / `incomingStartSec` |
| `blendDurationSec` | mashup blend window |
