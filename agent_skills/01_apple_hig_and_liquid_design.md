# 💎 Apple HIG & Liquid Glass Design System (2026 Standard)
*Стандарт дизайна интерфейсов уровня Apple Design Award.*

## 1. Визуальный стиль Liquid Glass (Apple Music):
- **Фон**: Динамический плавающий HDR Mesh-градиент на основе палитры текущей обложки трека. Плавное размытие (blur radius 40-70pt) с мягким покачиванием (fluid drift).
- **Обложка**: Квадратный RoundedRectangle(cornerRadius: 18, style: .continuous). При воспроизведении масштабируется с эффектом scaleEffect(isPlaying ? 1.0 : 0.88) с пружиной interactiveSpring(response: 0.38, dampingFraction: 0.75).
- **Материалы**: Использовать .ultraThinMaterial с темным оверлеем Color.black.opacity(0.25) и микро-бордерами .stroke(Color.white.opacity(0.14), lineWidth: 0.6).

## 2. Физика и тактильный отклик (Haptics & Spring):
- При любом нажатии на карточку трека или кнопку использовать пружинную компрессию (CardPressStyle: scaleEffect(isPressed ? 0.96 : 1.0)).
- При каждом значимом действии (Play/Pause, Like, смена трека) вызывать тактильную отдачу:
  UIImpactFeedbackGenerator(style: .medium).impactOccurred().
- Скруббер прогресса: непрерывная плавная полоса с отображением значка Lossless / Hi-Res / 320kbps и точным таймингом.

## 3. 100% Кликабельность и доступность:
- Все строки треков, карточки альбомов и кнопки должны иметь .contentShape(Rectangle()), чтобы клик срабатывал абсолютно в любой точке области.
- Для текущего воспроизводимого трека всегда показывать анимированные звуковые волны (LiveWaveEqualizer).
