# Equalizer: six-band reference (bass-tight)

## Approved controls
Actual filter centers (UI, AVAudioUnitEQ, streamed PCM and DualDeck):
**60 / 120 / 400 / 1000 / 2400 / 15000 Hz**.

Bass redesign vs the prior 60+150 @ 1-oct layout: that pair overlapped so “Глубина”
bled into mid-bass and the peak limiter then ducked kicks — heard as thin / cut bass.
Now the low shelf is steeper (bandwidth **0.55**), punch sits at **120 Hz** with
width **0.70**, mids **0.90**, high shelf **0.70**. Native PeakLimiter attack/decay
are gentler (**24 ms / 120 ms**) so boosts keep punch. Streamed C DSP matches the
same centers and widths (RBJ shelf slope from bandwidth).

First/last filters are low/high shelves; interior bands are parametric. Working
centers are capped at 0.44 × processing sample rate. Categories select two bands
each, without averaging or overwriting the curve.

All six controls now have the user-requested **−15…+15 dB** range, half-dB steps,
and a symmetric graph with 0 dB exactly in the middle. The screenshot's drawn +12 dB
point is an example value, not the requested new maximum. Native AU and C gain limits
match. Labels retain **2.4 kHz** rather than truncating this band to 2 kHz.

Double-tapping a node resets **only that band** to 0 dB and saves immediately.
The exclusive double-tap/drag gesture uses a movement threshold, with a shared
2D point hit test (24 pt radius). Empty graph space never resets another band.
Single tap selects, drag edits. Native zero buttons remain available to VoiceOver.

## Historical settings and presets
- Runtime marker: `eq.layout.bassTight6` (after `eq.layout.reference6`).
- Prior 60/150 curves are log-resampled onto 60/120 once; backup
  `eq.gains.bassTight6.backup`. Historical 10-/29-band upgrades still run first.
- Recognize both compact metadata layouts (30/40 Hz), old octave and dense grids.
  Resample gain values in log-frequency space onto the six new centers.
- Saved preset IDs/names remain unchanged, with original archives retained in
  `eq.userPresets.reference6.backup`. Six-band archives are never migrated twice.
- Old boosts above +15 dB are clamped to the new limit; the backup retains the old
  values. Moving from ten bands to six approximates a curve, not an exact acoustic
  match. Unknown/corrupt archives remain untouched; writes are refused.
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
Native AVAudioUnitEQ uses downstream Apple PeakLimiter (attack 0.012 s, decay
0.060 s, pre-gain 0 dB), respecting Apple's parameter ranges. Its envelope/ceiling
is not asserted to be the C algorithm. Slider ramps remain at least 90 ms, toggle/
route ramps at least 350 ms, with stale-ramp cancellation/generation guards.
Unsupported spatial/bitstream audio retains honest passthrough.

The six-dimensional SwiftUI vector animates control and response curves over
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
Portable tests compile/execute the actual six-band C source: all interior centers,
shelves, ±15 dB clamping, unity preamp, harmonics on sustained 40 Hz bass, actual
response-model agreement, channel isolation/stereo linking, hot sweeps/impulses,
rapid updates, invalid gains, 8/32/44.1/48/96 kHz, exact bypass and fade continuity.
Native macOS tests execute real AVAudioUnitEQ/PeakLimiter response, hot output,
parameter readback and stereo checks. The compiled Swift fixture runs preset CRUD,
legacy/compact/dense migration, backup preservation, repeated loads, unknown/corrupt
archives, symmetric graph round trips, point hit tests and haptic policy strength/
throttling. Linux skips native tests instead of claiming success.

Physical haptic feel and listening quality require a real iPhone/headphones at a
sensible volume. Synthetic measurements from the previous ten-band revision are
historical and must not be relabelled as six-band listening measurements.

## References
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/bandwidth
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/gain
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq/globalgain
- https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap
- Apple AudioUnitParameters.h: AUPeakLimiter global parameters.
