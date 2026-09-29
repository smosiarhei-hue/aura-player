# Сведение дублей AutoMix — карта и план миграции

Статус: **анализ + безопасная часть выполнены**. Полное удаление `Sonivo/Stage3*` требует
сборки (см. «Блокеры»), поэтому вынесено отдельным шагом.

## 1. Что у нас сейчас: четыре реализации

| # | Где | Что это | Статус |
|---|---|---|---|
| 1 | `Packages/AutoMixV2` (30 файлов, 7 модулей) | Основной движок: `TrackSource`, `TrackAnalysis`, `MixPlanner`, `AudioEngineCore`, `PlaybackCoordinator`, `MixDiagnostics` | **единственный движок** |
| 2 | `Packages/NeuroMix` | Нейро-планировщик переходов поверх (1) | оставить — не дубль |
| 3 | `Sonivo/Stage3*` (4 файла) | Параллельная пере-реализация `DualDeckAudioEngine` + `PlaybackCoordinator` + `MixDiagnosticsStore.textReport` | **удалены** ✅ |
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

## 3. Блокеры: почему удаление нельзя было сделать «просто так»

Проверено механически (сверка всех вызовов `coordinator.*` / `engine.*` в app-target с
публичным API пакета). Всё, что зовёт мост, в пакете было, **кроме** пяти мест:

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

## 4. План миграции — **ВЫПОЛНЕНО**

Важное уточнение к исходной оценке: граф пакетного движка был `player → gainMixer` и
**не содержал** FX-цепочки (это была особенность `Stage3*`). Поэтому перенос — это
добавление узлов в `DeckSlot`, а не просто сеттеры. Сделано так:

1. **`Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine`** — в `DeckSlot`
   добавлена цепочка деки ровно как в `docs/automix-stage4-acceptance.md`:
   `player → timePitch → fxEQ(4) → fxDelay → dryMixer → fxMixer → gainMixer`.
   Реализованы `setRate(_:for:)`, `applyEffect(_:value:param:bpm:to:)` и
   `resetEffects(_:preservingRate:)` со **взятым дословно** поведением стадии 4
   (dynamic Q на high-pass, bass kill −40 dB, echo-out 60/BPM*0.75, rate clamp 0.70…1.30,
   tape-stop, stutter, reverb wash, volume в dB, vocal ducking).
   `DeckSlot.resetFX()` возвращает деку в нейтральное состояние и вызывается из
   `stopLocked`, поэтому «застрявший фильтр/echo» невозможен — это критерий приёмки стадии 4.
2. **`Packages/AutoMixV2/Sources/PlaybackCoordinator/PlaybackCoordinator`** — добавлены
   `TransitionReadiness`, `transitionReadiness`, `transitionReason`, выведенные из
   собственного состояния координатора.
3. **`Sonivo/NeuroMixRealtimeAudioAdapter.swift`** — переведён на пакетный движок.
4. **`Sonivo/Stage3DiagnosticsBridge.swift`** — **удалён**: в пакете уже был свой
   `MixDiagnosticsStore.textReport(coordinator:)`, и мост-дубль его затенял.
5. **Удалены**: `Sonivo/Stage3DualDeckAudioEngine.swift`,
   `Sonivo/Stage3PlaybackCoordinator.swift`, `Sonivo/Stage3DiagnosticsBridge.swift`.
   Затенение имён исчезло: `DualDeckAudioEngine` / `PlaybackCoordinator` теперь
   однозначно указывают на `Packages/AutoMixV2`.
6. **Переименован** `Sonivo/Stage3ProfileEnricher.swift` → `Sonivo/TrackProfileEnricher.swift`
   (это **не** дубль, а живой мост между пакетным `TrackAnalysis` и легаси-анализаторами).

В проекте остался **один** движок воспроизведения — `Packages/AutoMixV2`.
Осталось: пересобрать IPA и пройти ручную приёмку из `docs/automix-stage4-acceptance.md`
(15 пар треков, pause/resume/seek во время перехода, смена аудиомаршрута).

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
