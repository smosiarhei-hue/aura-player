# AutoMix Mashup

## Логика «вау»-перехода (как делают диджеи)

Красивый Automix — это **короткая история**, не кроссфейд громкостей.

| Акт | Что слышит слушатель | Правило DJ |
|---|---|---|
| **LOCK** | Кики уже в одном темпе | Сетка / downbeat до того, как микс «заметен» |
| **INVITE B** | B входит гостем | Барабаны/тело B под A; не два лид-вокала сразу |
| **ONE BASS** | Пол выносит один бас | Бас A режется на доле → бас B владеет грувом |
| **MASHUP** | Оба слоя нарочно | Outro A (часто инструментал) × вокал/бит B — ощущение ремикса |
| **LAND** | Уже песня B | A уходит чисто; rate/pitch B в норму |

От этого «вау»: **один бас**, **одна вокальная доминанта** (ONE VOCAL — никогда два лида до LAND), стык на **фразе 8/16 тактов**, вход B не с тишины, выход A не в случайный мид-бар.

Если оба трека ещё поют в зоне cue → **ONE VOCAL**:
- DualDeck: `FxKind.instrumentalize` (karaoke mid-notch, Lab Mid/Side) на A и на B до handoff
- Live PlayerCore (AVPlayer): `MashupLiveStyle.oneVocalConflict` + `MashupLiveEQEnvelope.applyOneVocalGate`
- Вокал B открывается только на LAND

## Как это в Sonivo

Сведение считается **под каждую пару** треков: BPM / такт, **Бас от следующего**, **Мэшап-слой** A+B.

1. Анализ current/next → BPM, **Key/Camelot**, energy, mixIn/mixOut, downbeats (`TrackAnalyzer` / Lab `analyzeTrack` + `keyCamelot`)
2. Transition Planner §2.4 → тип: EQ Blend / Filter Sweep / Echo Out / Long Blend / Cut / Smart Crossfade (`transitionPlanner`)
3. План пары → rates, cues, DSP recipe, one-vocal (`MixPlanner` / Lab `planAutomix`)
4. Live → dual volumes + bass EQ + filters/echo + rate ramp (`MashupLiveStyle`, Lab dual-deck)
5. UI → Mixing на шкале; на handoff hard-snap обложки и таймлайна на B

Бейджи актов: `LOCK` → `INVITE B` → `ONE BASS` → `MASHUP` → `LAND` (Cut/Echo — свои фазы).

**§2.4 кратко:** BPM Δ>8% + несовместимые ключи → Echo/Cut; совместимые + близкий BPM → EQ/Long Blend; energy shift → Filter Sweep; короткий outro → Echo; иначе Smart Crossfade. Несовместимые ключи — короткий blend (§5).

## Automix Lab + AI (на компьютере)

```bash
cd tools/automix-lab && npm install && npm run dev
```

http://127.0.0.1:43187 — **✦ AI Auto Mix** сам разбирает оба трека (BPM + Camelot), выбирает тип §2.4 и ведёт акты.  
Smoke: `npm run smoke:tz`. Пара файлов: `npm run analyze:pair -- a.wav b.wav`.  
Craft: `tools/automix-lab/src/audio/djCraft.ts`.  
DSP с нуля: `tools/automix-lab/src/dsp/` — Mid/Side vocal/instrumental, bass EQ, HPF/LPF, echo-out.

## DualDeck V2

Ownership force-disabled. Live путь уже делает beatmatch + one-bass + mashup на AVAudioEngine / AVPlayer.

## Как слушать в приложении

Настройки → Переходы → **AutoMix Mashup**.
