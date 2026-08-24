# Aurora — Персональный музыкальный плеер для iOS

Aurora — это нативный плеер на SwiftUI с 10-полосным эквалайзером, живым спектром, анимированными обложками и стилистикой Liquid Glass.

## Возможности

- **Воспроизведение** — MP3, M4A/AAC, WAV, FLAC, AIFF (AVFoundation)
- **Эквалайзер** — 10 полос (31 Гц – 16 кГц), 9 пресетов, сохранение настроек
- **Спектр** — 32-полосный визуализатор в реальном времени (vDSP FFT)
- **Живые обложки** — анимированные градиентные арты по палитре трека (Canvas + TimelineView)
- **Пульсация** — обложка реагирует на басы
- **Импорт** — из «Файлов» / fileImporter / по прямой ссылке / через Finder
- **Библиотека** — поиск, избранное, свайп-действия, автоматическое сканирование
- **Оформление** — тёмная/светлая темы, 5 акцентных палитр, glassmorphism

## Структура проекта

```
aura-player/
├── .github/workflows/build-ipa.yml   # CI: macOS runner → unsigned IPA
├── project.yml                       # XcodeGen спецификация
├── Aurora/
│   ├── AuroraApp.swift               # @main, RootView, MiniPlayer
│   ├── Theme.swift                   # Settings, GlassCard, BackdropView
│   ├── Models.swift                  # Track, RepeatMode, EQPreset, Palette
│   ├── PlayerCore.swift              # AVAudioEngine, EQ, transport
│   ├── SpectrumAnalyzer.swift        # vDSP FFT 32 bands
│   ├── LibraryStore.swift            # Persistence, metadata, import
│   ├── Visuals.swift                 # AnimatedArtwork, SmallArtwork, SpectrumView
│   ├── LibraryView.swift             # Track list, search, filters
│   ├── PlayerScreen.swift            # Full player, gestures, scrubber, queue
│   ├── EqualizerView.swift           # Toggle, presets, 10 vertical sliders
│   ├── ImportView.swift              # Files, Finder, URL download, services info
│   ├── SettingsView.swift            # Theme, accent, about
│   └── Assets.xcassets/              # AppIcon, AccentColor
└── README.md
```

## Требования

- Аккаунт GitHub
- [eSign](https://esign.yuanfen.io) или [GBox](https://gbox.dev) на iPhone
- Личный сертификат Apple (.p12) и provisioning profile
  - Бесплатный Apple ID: сертификат действует 7 дней, потом переподпись
  - Платный девелоперский аккаунт ($99/год): действует 1 год

## Сборка через GitHub Actions

### 1. Создай репозиторий

```bash
cd aura-player
git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/ТВОЙ_ПОЛЬЗОВАТЕЛЬ/aura-player.git
git push -u origin main
```

> На публичном репозитории macOS-раннеры GitHub Actions бесплатны.
> На приватном — macOS-минуты тарифицируются в 10×.

### 2. GitHub Actions соберёт IPA автоматически

Каждый пуш в `main` запускает workflow:
- `xcodegen generate` — генерирует .xcodeproj из project.yml
- `xcodebuild` — собирает unsigned .app
- Упаковка в IPA и загрузка как артефакт

По тегу (например `v1.0.0`) — также создаёт GitHub Release с IPA.

### 3. Скачай unsigned IPA

GitHub → твой репо → Actions → последний успешный run → Artifacts → `Aurora-unsigned-ipa` → скачай `.ipa`.

## Установка через eSign

1. Открой eSign на iPhone
2. Нажми «Импорт IPA»
3. Выбери скачанный `Aurora-unsigned.ipa`
4. Перейди в «Подпись»
5. Выбери свой сертификат (.p12) и provisioning profile
6. При желании измени Bundle ID (по умолчанию `com.smoze.auroraplayer`)
7. Нажми «Подписать»
8. Установи — при первом запуске зайди в **Настройки → Основные → VPN и управление устройством** и доверяй сертификату

## Установка через GBox

1. Открой GBox
2. «Импорт» → выбери IPA
3. «Установить» → GBox подпишеет и поставит
4. Доверие сертификату аналогично eSign

## Импорт музыки

### Из приложения «Файлы» (рекомендуется)
1. Открой «Файлы» на iPhone
2. Перейди в раздел «Обзор» → Aurora
3. Скопируй или перетащи аудиофайлы
4. В Aurora: вкладка «Импорт» → «Обновить медиатеку»

### Через Finder (Mac)
1. Подключи iPhone к Mac
2. Finder → устройство → «Файлы» → Aurora
3. Перетащи файлы
4. Обнови медиатеку в приложении

### По прямой ссылке
1. Вкладка «Импорт» → «Импорт по ссылке»
2. Вставь URL на MP3/M4A/FLAC файл
3. Нажми «Скачать»

### Почему нет стриминга из Spotify / Яндекс / VK?

Эти сервисы не предоставляют API для полного скачивания треков сторонним приложениям — это защищено DRM и условиями использования. Aurora работает с вашими локальными файлами.

## Локальная сборка (опционально)

Если хочешь открыть проект в Xcode локально:

```bash
brew install xcodegen
cd aura-player
xcodegen generate
open Aurora.xcodeproj
```

Для симулятора: выбери iPhone Simulator как destination, запусти.

## Обновления

1. Пуш новых коммитов → Actions пересобирает IPA
2. Скачай новый артефакт
3. В eSign/GBox: удали старую версию → подпиши и установи новую

> Bundle ID при переподписи должен совпадать с предыдущим (или удали старое приложение).

## Устранение проблем

| Проблема | Решение |
|---|---|
| «Ненадёжный разработчик» | Настройки → Основные → VPN и управление устройством → доверяй |
| Приложение не открывается через 7 дней | Переподпись IPA (бесплатный сертификат истёк) |
| Actions не собирается | Проверь лог в GitHub Actions; скорее всего ошибка в Swift — пришли лог |
| Нет звука | Проверь, что iPhone не в беззвучном режиме; плеер использует audio background mode |
| Файлы не видны | Вкладка Импорт → «Обновить медиатеку» |

## Лицензия

Проект предоставляется как есть. Используй на свой риск.
