# Equalizer: standard 10-band ISO graphic

## Approved controls
Actual filter centers (UI, AVAudioUnitEQ, streamed PCM and DualDeck):
**31 / 62 / 125 / 250 / 500 / 1000 / 2000 / 4000 / 8000 / 16000 Hz**.

Standard music-player octave ladder. Ends are shelves with bandwidth **0.70**;
interior bands are true **1.0**-octave parametrics — even tone without muddy
overlapping bass shelves. Native PeakLimiter attack/decay stay gentle
(**24 ms / 120 ms**) so boosts keep punch. Streamed C DSP matches the same
centers and widths (RBJ shelf slope from bandwidth).

First/last filters are low/high shelves; interior bands are parametric. Working
centers are capped at 0.44 × processing sample rate. Categories select real
bands (low 31–125, middle 250–2k, high 4k–16k) without averaging or overwriting
the curve.

All ten controls have the user-requested **−15…+15 dB** range, half-dB steps,
and a symmetric graph with 0 dB exactly in the middle. Native AU and C gain
limits match.

Double-tapping a node resets **only that band** to 0 dB and saves immediately.
The exclusive double-tap/drag gesture uses a movement threshold, with a shared
2D point hit test (24 pt radius). Empty graph space never resets another band.
Single tap selects, drag edits. Native zero buttons remain available to VoiceOver.

## Historical settings and presets
- Runtime marker: `eq.layout.standard10` (after `eq.layout.bassTight6` /
  `eq.layout.reference6`).
- Prior six-band (60/120 or 60/150) and compact10 curves are log-resampled onto
  the ISO ladder once; backup `eq.gains.standard10.backup` (plus era backups
  `eq.gains.bassTight6.backup` / `eq.gains.reference6.backup`). Historical
  10-/29-band upgrades still run first.
- Recognize both compact metadata layouts (30/40 Hz), old octave, dense, and
  six-band grids. Resample gain values in log-frequency space onto the ten new
  centers.
- Saved preset IDs/names remain unchanged, with original archives retained in
  `eq.userPresets.standard10.backup` / `eq.userPresets.reference6.backup` /
  `eq.userPresets.bassTight6.backup`. Standard10 archives are never migrated twice.
- Old boosts above +15 dB are clamped to the new limit; the backup retains the old
  values. Moving between grids approximates a curve, not an exact acoustic match.
  Unknown/corrupt archives remain untouched; writes are refused.
- Factory recipes still use their explicitly declared legacy source grid, then
  convert to the current centers, so indices cannot silently shift meaning.

## Manual tactile response
Both native slider and graph dragging use the same control-side policy. A changed
half-dB step requests a discrete rigid impact, with intensity increasing from
0.16 near neutral to 0.90 at ±15 dB. Rate is limited to one impact per 60 ms.
No pulses for unchanged/nonfinite values; presets do not produce a haptic burst.
Double-tap reset uses its existing single light impact, not an extra intensity pulse.
The shared `hapticsEnabled` switch gates delivery. No changes to music haptics,
audio analysis or its timing. UIKit intensity is a request, not a calibrated motor
force; actual sensation depends on iPhone hardware and system settings.

## Stream DSP and peak protection
- Double-precision RBJ filters, independent channel histories, gains smoothed in dB
  over 30 ms. Intermediate coefficients are redesigned every 16 samples while
  moving; stable filters reuse coefficients. No direct pole-coefficient morph.
- Unity preamp: no fixed whole-song cut derived from the largest slider boost.
- Wet-path linked sample-peak guard: ceiling 0.98, immediate attenuation, 50 ms
  hold and 200 ms release time constant. A recurring crest within 0.5% of the held
  gain refreshes the hold, preventing periodic release/re-catch on sustained bass.
- Protect wet audio before the eased 350 ms mix toward original dry audio. Stable
  Flat/off remains exact C bypass; reversals resume from the current mix. No delay
  line, added stream latency or invented lyric/music-haptic synchronization offset.
- This is not true-peak limiting, headphone calibration or loudness normalization.
  Instantaneous catching can distort transients; holding can attenuate subsequent
  content. Strong boosts can reduce dynamics. Inter-sample peaks/hardware overload
  are not measured. Unlimited bass, unchanged perceived loudness and zero distortion
  cannot all be promised under the same output ceiling.
- Render processing is bounded and allocation-/lock-/sleep-/dispatch-free. Offline
  tests do not establish worst-case iPhone real-time CPU performance.

## Native processing and UI
Native AVAudioUnitEQ uses downstream Apple PeakLimiter (attack 0.024 s, decay
0.120 s, pre-gain 0 dB), respecting Apple's parameter ranges. Its envelope/ceiling
is not asserted to be the C algorithm. Slider ramps remain at least 90 ms, toggle/
route ramps at least 350 ms, with stale-ramp cancellation/generation guards.
Unsupported spatial/bitstream audio retains honest passthrough.

The ten-dimensional SwiftUI vector animates control and response curves over
240 ms; selection takes 180 ms. Direct manipulation is not delayed by decorative
animation; Reduce Motion disables it. Cadence is governed by iOS, not an unconditional
120 fps promise. The separate ±36 dB “Суммарная АЧХ · модель PCM 48 кГц” is a
small-signal theoretical sum of the exact C coefficients, before peak protection;
overlapping filters may exceed one slider's gain. It is not a spectrum meter,
headphone measurement or an exact model of Apple's native filter implementation.

No changes to Yandex negotiation, system volume/safety settings, playback queues,
other-app handoff, credentials, icons or music haptics. Experimental engines receive
settings only if already instantiated; this does not start them. The finite opaque
launch animation remains at the previously requested 1.5 s (Reduce Motion 0.35 s).

## Verification
Portable tests compile/execute the actual ten-band C source: all interior centers,
shelves, ±15 dB clamping, unity preamp, harmonics on sustained 40 Hz bass, actual
response-model agreement, channel isolation/stereo linking, hot sweeps/impulses,
rapid updates, invalid gains, 8/32/44.1/48/96 kHz, exact bypass and fade continuity.
Native macOS tests execute real AVAudioUnitEQ/PeakLimiter response, hot output,
parameter readback and stereo checks. The compiled Swift fixture runs preset CRUD,
legacy/compact/dense/six-band migration, backup preservation, repeated loads,
unknown/corrupt archives, symmetric graph round trips, point hit tests and haptic
policy strength/throttling. Linux skips native tests instead of claiming success.

Physical haptic feel and listening quality require a real iPhone/headphones at a
sensible volume. Synthetic measurements from prior six-/ten-band revisions are
historical and must not be relabelled as current listening measurements.

## References
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/bandwidth
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/gain
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq/globalgain
- https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap
- Apple AudioUnitParameters.h: AUPeakLimiter global parameters.
