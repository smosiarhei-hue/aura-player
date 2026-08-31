# 🛡️ Swift 6 Strict Concurrency & Architecture Standard
*Правила чистого кода для исключения крашей и ошибок компиляции.*

## 1. Swift 6 Observation Framework:
- Запрещено использовать устаревший ObservableObject / @Published в новых модулях.
- Все модели состояния объявляются как @Observable final class ModelName.
- Все UI-модели помечаются @MainActor для гарантии выполнения в главном потоке.

## 2. Безопасность разворачивания опционалов (Zero Crash Rule):
- **КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО** использовать принудительное разворачивание (!).
- Всегда использовать guard let, if let, ?? (дефолтные значения) или опциональную цепочку (?.).
- Пример: (player.currentBitrate ?? 0) >= 320, 	rack?.artworkURL ?? defaultURL.

## 3. Строгая типизация и расширяемость:
- Модели данных треков должны соответствовать Identifiable, Sendable, Equatable.
- Асинхронные вызовы сетевых потоков оборачивать в Task { @MainActor in ... } с обработкой ошибок do { ... } catch { ... }.
