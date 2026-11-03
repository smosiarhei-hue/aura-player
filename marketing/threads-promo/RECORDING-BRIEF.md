# Sonivo · screen recording brief (Threads / Reels)

Ты снимаешь — я монтирую. Клади файл в чат или в  
`marketing/threads-promo/raw/` (имя: `sonivo-demo.mov` / `.mp4`).

## Как снимать (iPhone)

1. **Настройки → Пункт управления** → добавь «Запись экрана».
2. Включи **Не беспокоить**, яркость ~70–80%, ориентация **портрет**.
3. Открой Sonivo, начни запись с **выключенным микрофоном** (если не нужна речь).
4. Цель: **45–75 секунд** сырого материала (я обрежу до 20–35 с для Threads).
5. Не закрывай Control Center поверх UI дольше 1 с.

## Шот-лист (порядок)

| # | Длительность | Что показать | Зачем |
|---|--------------|--------------|--------|
| 1 | 3–4 с | Home / Моя волна | бренд + лента |
| 2 | 5–7 с | Now Playing: обложка, play, scrub | «живой» плеер |
| 3 | 4–5 с | Lyrics / караоке (если есть) | тексты |
| 4 | 5–6 с | EQ: подвигай 2–3 полосы | звук |
| 5 | **12–18 с** | **AutoMix**: дождись `MIXING` → stems/бейдж → LAND на B | главный хук |
| 6 | 3–4 с | Библиотека / избранное | полнота |

**Важно для AutoMix:** не жми Next вручную. Дай треку дойти до mashup сам (или seek ближе к концу, ~dur−20 с), чтобы в кадре были `MIXING`, два трека и переход.

## Техтребования

- Формат: **.mov** или **.mp4**, H.264/HEVC
- Разрешение: нативный экран (не уменьшай)
- FPS: 30 или 60
- Размер: до ~200 MB ок; если больше — AirDrop → Files → сюда
- Без FaceTime-баннеров и уведомлений

## Что сделаю я после файла

1. Нарежу тайминг (хук AutoMix в первые 3 с финального ролика).
2. Вставлю в iPhone-frame / charcoal canvas 9:16 и 4:5.
3. Добавлю типографику SONIVO + captions из kit.
4. Выдам MP4 для Threads + 3–5 stills для карусели.

---

## Репозитории / тулы (качество)

| Инструмент | Для чего | Ссылка |
|------------|----------|--------|
| **Maya** | Screen → iPhone frame, zoom/tap, Reels export | https://github.com/ronaldo-avalos/Maya |
| **Bezelbub** | Точные Apple bezels + transparent video | https://github.com/cwooddgr/bezelbub |
| **MockupStudio** | 3D device + spotlight/blur promo | https://github.com/yusuftuhh/mockup-studio |
| **dejitech-mockup** | CLI: recording → mockup + platform presets | https://github.com/Deji-Tech/dejitech-mockup |
| **plaintext** | Swiss typography stills | https://github.com/Mendiak/plaintext |
| **guizang-social-card** | Editorial/Swiss карусель PNG | https://github.com/op7418/guizang-social-card-skill |

Локально у нас уже: `marketing/threads-promo/index.html` + type/hero cards.

---

## Промпты (если докручиваем AI / CapCut / Runway)

### A · Монтаж из твоего скринкаста (для меня / CapCut)

```
Take this iPhone screen recording of the Sonivo music app.
Export a 9:16 vertical promo, 22–28 seconds.
Structure: 0–2s brand title card "SONIVO" · 2–8s Now Playing · 8–20s AutoMix MIXING→LAND (hero) · 20–26s EQ + Wave flash · end card "AutoMix Mashup · iOS".
Style: dark charcoal background, realistic iPhone 16 Pro black titanium frame, soft drop shadow, no purple gradients, no emoji stickers, no stock music ducking the UI.
Typography: bold geometric sans, large "SONIVO", small captions in Russian: «ONE VOCAL × BEAT», «Моя волна», «10-band EQ».
Keep UI readable — mild zoom on MIXING badge only. Burn-in captions optional, high contrast white.
```

### B · Thumbnail / first frame (для GenerateImage / Midjourney)

```
Editorial product still, vertical 4:5. Black iPhone on deep charcoal #0B0C0E.
Screen shows Sonivo AutoMix: MIXING badge, two track titles, album art.
Huge white wordmark SONIVO top-left, Syne-like ultra bold.
Accent warm sand #D4A574 hairline. No purple, no glow blobs, no emoji.
Photoreal device, generous negative space, Swiss poster energy.
```

### C · Threads text (после видео)

```
SONIVO

Плеер, который сводит треки — не просто жмёт «далее».

AutoMix Mashup · Моя волна · 10-band EQ · lyrics

Смотри переход в видео ↓
```

---

## Чеклист перед отправкой

- [ ] AutoMix с `MIXING` попал в запись  
- [ ] Нет уведомлений  
- [ ] Портрет, без поворотов  
- [ ] Файл в чате или `marketing/threads-promo/raw/sonivo-demo.mov`
