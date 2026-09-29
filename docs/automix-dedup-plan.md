# Сведение дублей AutoMix — карта и план миграции

Статус: **анализ + безопасная часть выполнены**. Полное удаление `Sonivo/Stage3*` требует
сборки (см. «Блокеры»), поэтому вынесено отдельным шагом.

## 1. Что у нас сейчас: четыре реализации

| # | Где | Что это | Статус |
|---|---|---|---|
| 1 | `Packages/AutoMixV2` (30 файлов, 7 модулей) | Основной движок: `TrackSource`, `TrackAnalysis`, `MixPlanner`, `AudioEngineCore`, `PlaybackCoordinator`, `MixDiagnostics` | **выбран как целевой** |
| 2 | `Packages/NeuroMix` | Нейро-планировщик переходов поверх (1) | оставить — не дубль |
| 3 | `Sonivo/Stage3*` (4 файла) | Параллельная пере-реализация `DualDeckAudioEngine` + `PlaybackCoordinator` | **дубли → удалить** |
| 4 | `Sonivo/AutoMix/` (18 файлов) | Легаси-анализ: BPM / тональность / структура / планировщик переходов | см. «Не дубли» |
| 5 | `Sonivo/DJAutoMixEngine/` (8 файлов) | Ещё одна DJ-реализация (coordinator / planner / renderer / sync) | см. «Не дубли» |

## 2. Главная опасность: молчаливое затенение типов

`Sonivo/Stage3DualDeckAudioEngine.swift` и `Sonivo/Stage3PlaybackCoordinator.swift`
объявляют типы **`DualDeckAudioEngine`** и **`PlaybackCoordinator`** — ровно с теми же
именами, что и `Packages/AutoMixV2`.

Правила поиска имён Swift предпочитают объявление **внутри текущего модуля** импортированному,
поэтому во всём app-target эти имена молча указывают на `Stage3*`-версии, а не на пакетные.

При этом `Sonivo/AutoMixV2AppBridge.swift` написан **под API пакета** (импортирует
`AudioEngineCore`, `PlaybackCoordinator`, `TrackSource`, `TrackAnalysis`) — то есть мост
«AutoMix V2» на самом деле тихо поднимает пере-реализацию из `Stage3*`. Это и есть класс
«что-то конфликтует»: типы с одинаковыми именами, разным поведением и разным местом в
поиске имён.

Тестовый таргет (`SonivoUnitTests`) `Stage3*` не компилирует, поэтому тесты проверяют
пакетные типы, а приложение играет через `Stage3*` — расхождение не ловится никаким тестом.

## 3. Блокеры: почему удаление сейчас сломает сборку

Проверено механически (сверка всех вызовов `coordinator.*` / `engine.*` в app-target с
публичным API пакета). Всё, что зовёт мост, в пакете есть, **кроме**:

### Блокер 1 — три FX-метода движка
`Sonivo/NeuroMixRealtimeAudioAdapter.swift` (класс `NeuroMixRealtimeTransitionRunner`
используется из `AutoMixV2AppBridge`) зовёт на `DualDeckAudioEngine`:

| Метод | Где зовётся | Есть в `Packages/.../DualDeckAudioEngine` |
|---|---|---|
| `setRate(_:for:)` | `NeuroMixRealtimeAudioAdapter.swift:30, 89, 102, 107` | ✗ |
| `applyEffect(...)` | `NeuroMixRealtimeAudioAdapter.swift:41` | ✗ |
| `resetEffects(_:)` | `NeuroMixRealtimeAudioAdapter.swift:87, 88, 103, 108` | ✗ |

### Блокер 2 — два свойства координатора
`Sonivo/Stage3DiagnosticsBridge.swift` (его `textReport` зовётся из
`AutoMixV2AppBridge.swift:599`) читает у `PlaybackCoordinator`:

| Свойство | Есть в `Packages/.../PlaybackCoordinator` |
|---|---|
| `transitionReadiness` | ✗ |
| `transitionReason` | ✗ |

Итого удаление `Sonivo/Stage3*` = перенос **3 методов движка + 2 свойств координатора**
в `Packages/AutoMixV2`, затем удаление 4 файлов и правка 2 файлов-потребителей.

## 4. План миграции (конечный, ~1 PR)

1. **`Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine`**
   добавить `setRate(_:for:)`, `applyEffect(...)`, `resetEffects(_:)`.
   Граф деки уже содержит нужные узлы
   (`AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitEQ → AVAudioUnitDelay → mixer`),
   так что это локальные сеттеры параметров, а не новая архитектура.
   Обязательно: поведение `resetEffects` — возврат в нейтральное состояние
   (rate 1.0, EQ 0, delay 0), как того требует `docs/automix-stage4-acceptance.md`
   («Previous, stop и interruption возвращают нейтральные EQ, delay и rate»).
2. **`Packages/AutoMixV2/Sources/PlaybackCoordinator/PlaybackCoordinator`**
   добавить `transitionReadiness: TransitionReadiness` + `transitionReason: String`
   с той же семантикой, что в `Sonivo/Stage3PlaybackCoordinator.swift:43-44, 677-679`.
3. **`Sonivo/NeuroMixRealtimeAudioAdapter.swift`** — типы-параметры перевести на
   пакетный `DualDeckAudioEngine` (имя станет однозначным само после шага 5).
4. **`Sonivo/Stage3DiagnosticsBridge.swift`** — `textReport(coordinator:)` перевести на
   пакетный `PlaybackCoordinator`.
5. **Удалить**: `Sonivo/Stage3DualDeckAudioEngine.swift`,
   `Sonivo/Stage3PlaybackCoordinator.swift`, `Sonivo/Stage3DiagnosticsBridge.swift`.
   После этого `DualDeckAudioEngine` / `PlaybackCoordinator` в app-target однозначно
   указывают на пакет — затенение исчезает.
6. **Переименовать** `Sonivo/Stage3ProfileEnricher.swift` → `TrackProfileEnricher`
   (это **не** дубль, а живой мост между пакетным `TrackAnalysis` и легаси-анализаторами;
   используется из `Sonivo/AutoMixV2AnalysisRuntime.swift:89, 98`). Убираем протухшее
   имя этапа, файл оставляем.
7. Пересобрать IPA и пройти ручную приёмку из `docs/automix-stage4-acceptance.md`
   (15 пар треков, pause/resume/seek во время перехода, смена аудиомаршрута).

После этого в проекте останется **один** движок воспроизведения — `Packages/AutoMixV2`.

## 5. Не дубли — что оставляем

- **`Sonivo/AutoMix/MoodRadioEngine.swift`** (589 строк) — «Мои волны» / mood radio,
  уникальная фича, 12 внешних файлов-потребителей.
- **`Sonivo/AutoMix/TransitionPlanner.swift` + его extensions**
  (`AutoMixTransitionEnvelopes/Timing/Validation`, `TransitionPlanSanitizer`,
  `AutoMixTempoMatch`) — это реализация легаси-планировщика, разложенная по файлам, а
  не копия. Её потребитель — `Sonivo/playercore.swift` (живой путь воспроизведения).
- **`Sonivo/AutoMix/TrackAnalysisService.swift`, `BeatAnalyzer`, `KeyDetector`,
  `StructureAnalyzer`, `CamelotWheel`, `AutoMixDSP`** — легаси-анализ. Функционально
  перекрывается `Packages/AutoMixV2/Sources/TrackAnalysis`
  (`PulseTempoEstimator`, `HarmonicKeyDetector`, `TrackAnalyzer`), но подключён к
  `playercore` и `DJAutoMixEngine/TrackAnalyzer`. Замена меняет определение BPM/тональности,
  значит требует прослушивания — не делается вслепую.
- **`Sonivo/AutoMix/SmartNextTrackSelector.swift`, `GeminiAutoMixPlanner.swift`** —
  используются `playercore`/`models`. `GeminiAutoMixPlanner` при этом вводит в заблуждение
  именем: внутри нет Gemini-клиента, только модельные типы (`TransitionPlan`,
  `TransitionAction`, `TransitionEffects`) и локальный fallback.
- **`Sonivo/AutoMix/AutoMixAnalysisSnapshot.swift`, `AutoMixLookaheadWarmer.swift`** —
  связаны с `MoodRadioEngine` / `SmartNextTrackSelector`.
- **`Sonivo/DJAutoMixEngine/*`** — связаны в один подграф и достижимы из
  `playercore` (`DJPreCacheWorker`) и `DJMixModels` (`DifySettingsSheet`,
  `OnDeviceVocalAligner`, `KeyDetector`).

## 6. Уже сделано (безопасная часть)

- Устранено расхождение **состояния эквалайзера**: `Sonivo/Stage3DualDeckAudioEngine.swift`
  читал `UserDefaults` сам, через `bool(forKey:)` — что отвечает `false` для отсутствующего
  ключа, тогда как `PlayerCore` по умолчанию включает эквалайзер. Итог: дека AutoMix V2 /
  NeuroMix играла с обходом EQ, пока интерфейс показывал его включённым. Теперь один
  читатель — `PlayerCore.persistedEQ()`, кривая нормализуется к числу полос везде.
