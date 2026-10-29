# Equalizer: bass-shake 10-band (clean punch)

## Approved controls
Actual filter centers (UI, AVAudioUnitEQ, streamed PCM and DualDeck):
**60 / 120 / 250 / 500 / 1000 / 2000 / 4000 / 8000 / 12000 / 16000 Hz**.

Goal: headphones that **shake** on sub/kick without muffling the rest of the mix.

- **60 Hz low shelf** (slope **0.90**) — energy in the 40–80 Hz driver-shake band.
  The prior ISO **31 Hz** shelf left that band only half-boosted, so users piled on
  several low sliders and then heard the peak guard duck the song.
- **120 Hz peaking** (width **0.65**) — kick punch, kept above the shelf knee.
- **250 Hz peaking** (width **0.80**) — mud control; bass presets cut here.
- Higher bands **1.0** oct; high shelf **0.70**.

Native PeakLimiter: attack **40 ms** (let kick transients through), decay **80 ms**
(restore body quickly). Streamed C DSP matches centers/widths; sample-peak hold is
**16 ms** with **~110 ms** release and **no crest-hold refresh** (refreshing on every
bass crest used to park attenuation on EDM/hip-hop — heard as muffled bass).

First/last filters are low/high shelves; interior bands are parametric. Working
centers are capped at 0.44 × processing sample rate. Categories select real bands
(low 60–250, middle 500–4k, high 8k–16k) without averaging or overwriting the curve.

All ten controls have **−15…+15 dB**, half-dB steps, and a symmetric 0 dB graph.
Native AU and C gain limits match. Unity preamp remains: no fixed whole-song cut
from the largest slider; the peak guard only acts on actual overs.

Double-tapping a node resets **only that band** to 0 dB and saves immediately.
Exclusive double-tap/drag, 24 pt hit test. Empty graph space never resets another band.

## Historical settings and presets
- Runtime marker: `eq.layout.bassShake10` (after `eq.layout.standard10` /
  `eq.layout.bassTight6` / `eq.layout.reference6`).
- Prior ISO 31–16k, compact10, and six-band curves are log-resampled once; backup
  `eq.gains.bassShake10.backup` (plus era backups). Historical upgrades still run first.
- Factory bass recipes are authored on this grid: strong 60+120, cut 250 mud, flat mids.
- Saved preset IDs/names survive; archives in `eq.userPresets.bassShake10.backup` /
  `eq.userPresets.standard10.backup` / six-band backups. Never migrate twice.
- Unknown/corrupt archives remain untouched; writes are refused.

## Manual tactile response
Unchanged: half-dB steps, intensity 0.16…0.90, 60 ms throttle, `hapticsEnabled` gate.

## Stream DSP and peak protection
- Double-precision RBJ filters, independent channel histories, gains smoothed in dB
  over 30 ms. Intermediate coefficients redesigned every 16 samples while moving.
- Unity preamp; wet-path linked sample-peak guard at ceiling **0.98**.
- Short hold + fast release; no recurring-crest hold refresh (that muffled bass).
- Protect wet before the eased mix toward dry. Flat/off remains exact C bypass.
- Not true-peak limiting, headphone calibration or loudness normalization.
  Strong boosts can still reduce dynamics if the source is already brickwalled.
- Render processing stays allocation-/lock-/sleep-/dispatch-free.

## Native processing and UI
Native AVAudioUnitEQ + Apple PeakLimiter (attack 0.040 s, decay 0.080 s, pre-gain 0).
Slider ramps ≥90 ms; toggle/route ≥350 ms. Spatial/bitstream stays honest passthrough.

Ten-dimensional SwiftUI curve animation 240 ms; selection 180 ms; Reduce Motion off.
“Суммарная АЧХ · модель PCM 48 кГц” is the theoretical C coefficient sum before the
peak guard — not a headphone measurement.

## Verification
Portable C tests: centers, shelves, ±15 dB, unity preamp, sustained 40 Hz harmonics,
response model, channel isolation, hot sweeps, rates, bypass. Native macOS AU/limiter
checks where available. Swift fixture: preset CRUD, migrations, backups, graph, haptics.
Listening quality still requires a real device and headphones.

## References
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/bandwidth
- Apple AudioUnitParameters.h: AUPeakLimiter global parameters.
