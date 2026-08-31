# ⚡ Swift 6 & Audio Engine Architecture (2026 Edition)

## Архитектурные стандарты:
1. **Swift 6 & Concurrency**:
   - Использование Observation фреймворка: @Observable final class PlayerCore вместо устаревшего ObservableObject / @Published.
   - Главные UI-модели и плеер должны быть изолированы на @MainActor.
   - Полная совместимость со строгой конкурентностью (SWIFT_STRICT_CONCURRENCY: complete).

2. **Аудио-движок и фоновое воспроизведение**:
   - Поддержка AVAudioSession.sharedInstance().setCategory(.playback, mode: .default).
   - Интеграция с MPNowPlayingInfoCenter и MPRemoteCommandCenter для управления с экрана блокировки и Dynamic Island.
   - Безопасное разворачивание опционалов (например, битрейт (player.currentBitrate ?? 0) >= 320).
   - Кэширование аудиопотоков и обложек для плавной смены треков.
