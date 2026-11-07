# AutoMix / Mashup — полный бриф для проверки другим ИИ

**Репо:** `aura-player`  
**Ветка:** `feature/modern-my-wave-home`  
**Док в репо (продуктовая логика):** `docs/automix-mashup.md`  
**Цель проверки:** убедиться, что live Automix на PlayerCore соответствует контрактам ниже; DualDeck V2/Neuro ownership не включены случайно; регрессии volA≈0.64 / LAND dual-vol / bpm0 / cold cueB закрыты.

---

## 1. Что считается «готовым» AutoMix

Красивый Automix — не кроссфейд громкостей, а короткая DJ-история:

| Акт | Смысл |
|---|---|
| LOCK | Темп уже совпал |
| INVITE B | B входит гостем под A |
| ONE BASS | Пол один — бас A режется, бас B владеет |
| MASHUP | Outro A × вокал/бит B |
| LAND | Чистый выход в песню B |

**ONE VOCAL:** никогда два лид-вокала до LAND.

Включение в приложении: **Настройки → Переходы → AutoMix Mashup** (также есть Duet).

---

## 2. Ownership (критично)

| Движок | Роль | Live? |
|---|---|---|
| **PlayerCore** (`Sonivo/playercore.swift`) | Playback + live Automix/Duet/crossfade | **ДА — единственный live path** |
| **AutoMixV2AnalysisRuntime** | BPM/key/plan/stem analysis → стиль | **ДА (только анализ)** |
| **AutoMixV2Runtime DualDeck** | DualDeck ownership | **FORCE-DISABLED** |
| **NeuroMixRuntime** | Neuro DualDeck | **FORCE-DISABLED** |

Проверить, что остаётся `false`:

- `ActivePlayerPresentation`: `v2OwnsPlayback`, `neuroOwnsPlayback`, `isV2Enabled`
- `AutoMixV2AppBridge`: `isV2Enabled` / `isNeuroEnabled` getters всегда `false`; `owner(for:)` → `.legacy`; `play` всегда в `PlayerCore`

Цепочка: UI → `ActivePlayerPresentation` → `PlaybackCommandRouter` → **PlayerCore**.

---

## 3. Live-пайплайн (что происходит)

1. Близко к outro → `resolveMashupBlend`  
   MixPlanner plan → profile → MoodAutomix → **`MashupBlendScheduler`** (длина бленда из cues, **не слайдер**)
2. `resolveMashupStyle` → **`MashupLiveStyle.resolve`** + character (Automix / Duet)
3. Ранний arm B (`pendingMashupLiveArm`); если bake опаздывает → **live Automix на cue** на dry dual decks (не тишина)
4. Предпочтительно HTDemucs / MidSide bake → `playMashupStemPair`
5. `tickTransition` **@ 60 Hz**: volumes, EQ, pitch/rate, phrase loops, LAND
6. LAND → `completeTransition` → `landAutomixOntoDryB` + `startLandGlide`

---

## 4. Ключевые файлы

### Планирование / стиль

- `Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift` — volumes, rates, pitch, LAND, bed, фазы
- `Packages/AutoMixV2/Sources/MixPlanner/MashupBlendScheduler.swift` — cue A/B + длина бленда
- `Packages/AutoMixV2/Sources/MixPlanner/MoodAutomix.swift` — mood window / landProgress
- `Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift` — TransitionPlan, tempoMatch ±8%
- `Packages/AutoMixV2/Sources/MixPlanner/NeuralAutomixCue.swift` — LRC/Whisper phrase-end
- `Packages/AutoMixV2/Sources/MixPlanner/MashupTransitionExecutor.swift` — DualDeck FX (dormant ownership)

### Live runtime

- `Sonivo/playercore.swift` — dual-deck, bake, tick, LAND, phrase loops
- `Sonivo/MixPlanRealtimeTransitionRunner.swift` — `MashupLiveEQEnvelope`
- `Sonivo/streambeat.swift` — EQ override на streaming AVPlayer
- `Sonivo/AutoMixV2AnalysisRuntime.swift` — профили/план
- `Sonivo/models.swift` → `AutoMixDJEngine` — badge/progress chrome
- `Sonivo/AutoMixV2AppBridge.swift` — router + force-disable
- `Sonivo/ActivePlayerPresentation.swift` — facade

### Stems

- `Packages/AutoMixV2/.../MidSideStemBaker.swift`
- `Packages/AutoMixV2/.../StemSplit/HTDemucsMashupBake.swift` (on-device, ~400MB first download)

### Lab (не shipping iOS)

- `tools/automix-lab/` + `tools/automix-lab/docs/APPLE-AUTOMIX-SPEC.md`

### Docs

- `docs/automix-mashup.md`
- `docs/automix-stage{1–4}-acceptance.md`
- `docs/automix-dedup-plan.md`

---

## 5. Константы / тюнинг (ревьюеру сверить с кодом)

### Volumes (`MashupLiveStyle`)

- `appleAutomixVolumes`: A taper → **`aHold = 0.82`** → fade к LAND; B quiet bed → bloom ~последние 18% → 1.0
- **`stemNeuralVolumes` ≡ `volumes()` / apple path** — **нет karaoke plateau `volA=0.64`** (field 1153)
- `automixIncomingBedGain`: default **0.52**; oneVocal **0.44**; echoFreeze/spaceReverb **0.40**; `|pitchCentsB|≥50` → **0.36**
- `automixLandProgress`: moodLand ∈ [0.58, 0.93] иначе handoff ∈ [0.84, 0.92]
- Automix character: handoff ∈ **[0.84, 0.90]** (~0.88)

### Blend scheduler

- min blend **4s**, max **32s**, preferred default **8s**
- `minimumPlayedFraction=0.75`, `minimumTailSec=6`, **`minimumIncomingCueSec=4.0`**
- Cold **cueB=0.1 запрещён** → floor ≥ 4s

### MoodAutomix

- shortest **5.5s**, longest **26s**

### LAND dual-vol (`playercore`)

- Hard-cut по **`automixLandProgress`**, не сырой `handoffAt` (кроме Duet-логики)
- Call `glideSec ≈ 0.14`; clamp overlap **~0.10–0.18s**
- Dry стартует на уровне stem; stem ≤ ~22% и умирает — иначе volA+volB ≫ 1 bump

### Tempo / pitch

- **`tempoMatch` ±8%**, A-locked — **без** geometric mean / half-time octave
- Automix pitch ±100¢; Duet ±300¢

### Прочее

- Tick **60 Hz**
- Post-LAND suppress track-finish / next ≈ **2.0s**
- Phrase loops: `seekOutgoingPhraseLoop()` — **не** публичный `seek(to:)` (seek отменяет mashup)
- Loops выкл. после stem tile; только пока `p < landAt * 0.72`

---

## 6. UI / chrome

- Settings: Gapless / Crossfade / **AutoMix Mashup** / Duet / Off; слайдер длительности только у Crossfade (**нет mashup duration slider**)
- Badge «Mixing» / «Сведение» только когда переход **слышен** (`isTransitionActive` не на bake lead-in)
- Timeline = живые часы A до LAND; scrub/seek → `cancelTransition()`
- Stem chip = прогресс HTDemucs (отдельно от Mixing)
- Session log: toggle / copy / clear (`AutoMixSessionLog`)
- V2 diagnostics UI существует, но selection getters → «Обычный»

---

## 7. Что НЕ относится к AutoMix (не путать)

Workers Cloudflare (`sonivo-ai` curator Gemini) — **не** Automix DSP.  
Недавний Now Playing UI (cover blur, folding swipe, lyrics morph) — **отдельный трек**, не часть Automix.

---

## 8. Тесты, которые должны зеленеть

### Scripts

- `.github/scripts/test_automix_mashup.py` — главный source-contract
- `.github/scripts/test_automix_dta_fallback.py` — `dta?` / private-copy m4a
- `.github/scripts/test_analyze_automix_session_log.py`
- `.github/scripts/test_notify_automix_telegram.py`

### UnitTests

- `MashupLiveStyleTests.swift` — quiet B bed, A taper, LAND, **stemNeural≡apple**, bed ≤0.62
- `MashupBlendSchedulerTests.swift` — outro≥75%, cold cueB floor
- `MoodAutomixTests.swift`
- `MashupTransitionExecutorTests.swift`
- `MixPlannerStage2Tests.swift`, `Stage3BeatMatchTests.swift`, `Stage4EffectsTests.swift`
- `NeuralAutomixCueTests.swift`
- `NeuroMixEngineTests.swift` (ownership dormant)
- `TrackAnalyzerStage2Tests.swift`, `MixDiagnosticsTests.swift`

Запуск ориентир:

```bash
python3 .github/scripts/test_automix_mashup.py -v
```

+ XCTest unit suite Mashup*

---

## 9. Регрессии, которые уже чинили (проверить, что не вернулись)

| Симптом / field | Фикс (тема коммита) |
|---|---|
| Karaoke **volA=0.64** plateau | `stemNeuralVolumes` = apple volumes (`b849234`) |
| LAND loudness bump (dual vol) | короткий glide 0.10–0.18, dry@stem (`ee8595a`, `b849234`) |
| Fake half-time beatmatch 66↔99 | tempoMatch ±8% only (`1e1ea43`, `dbdfc63`) |
| bpm0 / live-cache analysis | private copy + bake-local profile (`35f466e`, `eda7e39`) |
| Cold cueB=0.1 | floor ≥4s (`0d6b649`, `dbdfc63`) |
| Mix at EOF instead of cue | fire at musical cue; arm B early (`1312d47`, `0d6b649`) |
| Silent B / volB=0 | dual native decks; live if bake late (`6a169e7`, `f0322ff`) |
| Mixing badge too early | only when audible (`a477685`) |
| EQ guard wrong flag | `isTransitioning` not chrome (`108d7f1`) |
| Phrase loops broken | restore + seekOutgoingPhraseLoop (`94ca249`, `bfc1392`) |
| Echo after LAND | kill post-LAND echo (`232ae53`) |
| Locked m4a/`dta?` | private copy + AVAssetReader fallback |
| Zombie MIXING after starve | cancel/land guards (`5f334e0`) |
| Sendable bakeTask race | Swift 6 fix (`b5fe48d`) |

Недавние Automix-коммиты (новые сверху):  
`b849234`, `dbdfc63`, `1e1ea43`, `b5fe48d`, `ee8595a`, `b6ecfef`, `35f466e`, `5857bb1`, `bfc1392`, `94ca249`, `447a262`, `eda7e39`, `a477685`, `108d7f1`, `f0322ff`, `6a169e7`, …

---

## 10. Инварианты для чеклиста ревьюера

1. Seek / scrub → `cancelTransition()`; phrase loop **не** через публичный seek
2. Streaming EQ только через `StreamBeatTap` overrides, без re-download
3. LAND dual-vol короткий; нет длинного dual fade одного контента
4. `stemNeuralVolumes == appleAutomixVolumes` (нет 0.64 plateau)
5. Ownership всегда legacy
6. Mixing chrome только когда слышно
7. LAND по `automixLandProgress`
8. Post-LAND suppress ~2s; cancel не сбрасывает live LAND suppress окна ошибочно
9. cueB ≥ 4s
10. tempoMatch ±8% only
11. Не reopen live m4a/mp3 для bake
12. `isCompletingTransition` против double LAND
13. Timeline = A clock до LAND
14. EQ single-writer (`applyEQ`)
15. Bake late → live dry Automix, не silent equal-power

---

## 11. Как воспроизвести вручную

1. Настройки → AutoMix Mashup
2. Очередь ≥2 трека с разными BPM/ключами
3. Доиграть до outro / форсировать near-end
4. Слушать: bed B → bloom → LAND без громкостного удара
5. Badge Mixing появляется с аудио, не за 10с до
6. Scrub во время микса → микс отменяется
7. После LAND ~2с next/finish не дёргают
8. При возможности — пара с LRC (neural cue на фразу)

---

## 12. Архитектурный скелет

```
Settings(.automix | .duet)
  → ActivePlayerPresentation
    → PlaybackCommandRouter → PlayerCore (LIVE dual AVAudioEngine/AVPlayer)
    → AutoMixV2AnalysisRuntime → MashupLiveStyle / MashupBlendScheduler / MixPlanner
    → AutoMixDJEngine (badge only)
    → AutoMixV2Runtime / NeuroMixRuntime (ownership OFF)
```

**Первичные файлы ревью:**

- `Sonivo/playercore.swift`
- `Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift`
- `Packages/AutoMixV2/Sources/MixPlanner/MashupBlendScheduler.swift`
- `Sonivo/MixPlanRealtimeTransitionRunner.swift`
- `Sonivo/ActivePlayerPresentation.swift`
- `Sonivo/AutoMixV2AppBridge.swift`
- `Tests/UnitTests/MashupLiveStyleTests.swift`
- `.github/scripts/test_automix_mashup.py`
- `docs/automix-mashup.md`
