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

От этого «вау»: **один бас**, **одна вокальная доминанта**, стык на **фразе 8/16 тактов**, вход B не с тишины, выход A не в случайный мид-бар.

## Как это в Sonivo

Сведение считается **под каждую пару** треков: BPM / такт, **Бас от следующего**, **Мэшап-слой** A+B.

1. Анализ current/next → BPM, energy, mixIn/mixOut, downbeats (`TrackAnalyzer`)
2. План пары → rates, cues, архетип (`MixPlanner` / Lab `planAutomix`)
3. Live → dual volumes + bass EQ + rate ramp (`MashupLiveStyle`, `MashupLiveEQEnvelope`)
4. UI → Mixing на шкале; на handoff hard-snap обложки и таймлайна на B

Бейджи актов: `LOCK` → `INVITE B` → `ONE BASS` → `MASHUP` → `LAND`.

## Automix Lab + AI (на компьютере)

```bash
cd tools/automix-lab && npm install && npm run dev
```

http://127.0.0.1:43187 — **✦ AI Auto Mix** сам разбирает оба трека и ведёт 5 актов.  
Craft: `tools/automix-lab/src/audio/djCraft.ts`.  
DSP с нуля: `tools/automix-lab/src/dsp/` — Mid/Side vocal/instrumental, bass EQ, HPF/LPF, echo-out.

## DualDeck V2

Ownership force-disabled. Live путь уже делает beatmatch + one-bass + mashup на AVAudioEngine / AVPlayer.

## Как слушать в приложении

Настройки → Переходы → **AutoMix Mashup**.
