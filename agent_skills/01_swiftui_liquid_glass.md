# 🎨 SwiftUI & Apple Music Liquid Design Skill (2026 Edition)

## Основные правила интерфейса:
1. **Apple Music Visual Standard**:
   - Динамический размытый HDR фон с плавной градиентной анимацией (MeshGradient / fluid motion blur).
   - Обложка трека: квадратный RoundedRectangle(cornerRadius: 16) с плавной физической пружиной interactiveSpring(response: 0.35, dampingFraction: 0.8).
   - Название трека и артист: четкая типографика Apple SF Pro Display (Title 2 Bold для трека, Subheadline для артиста).
   - Скруббер (ползунок прогресса): интерактивный с бейджем формата (Lossless / Hi-Res / 320kbps).
   - Транспортные кнопки: белый цвет .white, чистый стиль, тактильный отклик (UIImpactFeedbackGenerator).

2. **100% Кликабельность элементов**:
   - Любые карточки и строки треков (ChartRowView, TrackCardView, CatalogRow) должны быть полностью кликабельными по всей площади (.contentShape(Rectangle()) / CardPressStyle).
   - Добавление анимированного звукового эквалайзера (LiveWaveEqualizer) для текущего играющего трека.

3. **Современные анимации SwiftUI**:
   - Использовать .animation(.spring(response: 0.4, dampingFraction: 0.75), value: ...) для всех переходов.
   - Использовать Liquid Glass материалы: .ultraThinMaterial с темным тонированием и тонкими бордерами (.stroke(Color.white.opacity(0.12), lineWidth: 0.5)).
