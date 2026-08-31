# 🎧 Pro Audio Streaming Engine & LockScreen Integration
*Стандарты надежного воспроизведения аудио на iOS.*

## 1. Фоновое воспроизведение и аудио-сессия:
- Конфигурация сессии: AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth]).
- Активация сессии перед началом воспроизведения: 	ry? AVAudioSession.sharedInstance().setActive(true).

## 2. Экран блокировки (Now Playing Info Center):
- Обязательная передача метаданных в MPNowPlayingInfoCenter.default().nowPlayingInfo:
  - MPMediaItemPropertyTitle (Название)
  - MPMediaItemPropertyArtist (Артист)
  - MPMediaItemPropertyArtwork (Обложка)
  - MPMediaItemPropertyPlaybackDuration (Длительность)
  - MPNowPlayingInfoPropertyElapsedPlaybackTime (Текущее время)
  - MPNowPlayingInfoPropertyPlaybackRate (1.0 при воспроизведении, 0.0 при паузе)
- Интеграция с MPRemoteCommandCenter для кнопок Play, Pause, Next, Previous, Seek.
