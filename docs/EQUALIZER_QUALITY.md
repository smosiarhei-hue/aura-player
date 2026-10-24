# Equalizer: quality revision

## Scope and invariants
Ten real filters: 40 / 60 / 120 / 250 / 500 / 1k / 2k / 4k / 8k / 15k Hz.
Low/middle/high categories select a band, never average or overwrite a curve.
First/last filters are shelves, interior filters are parametric. The 60 Hz bell
now has a 0.75-octave width to reduce overlap with the 40 Hz shelf; other bells
remain one octave. Native, streamed PCM and already-existing experimental deck
engines use matching centers, types and bandwidth settings. Native AU's internal
filter implementation is Apple's; bit-identical responses are not asserted.
Centers remain capped at 0.44 × sample rate.

User curves, preset identifiers, persistence and migrations are preserved. Only
the extreme factory “Мощный саббас” recipe is moderated (legacy-grid values
9 / 5 / 2 / −1 / −0.5 / 0 / 0 / 0 / 0 / 0 before existing grid migration).
Saved user presets are not rewritten. Bass controls still allow −12…+18 dB;
other bands −12…+12 dB. Large boosts now show a restrained distortion/dynamics hint.

No changes to Yandex quality negotiation, system volume/safety controls, queues,
account credentials, icons, handoff to other apps or music-haptic synchronization.
AutoMix/Neuro are never enabled or instantiated just to apply EQ.

## Streamed PCM DSP
- Double-precision transposed direct-form-II RBJ filters and per-channel histories.
- Smooth gains in dB over a 30 ms time constant, with coefficient redesign every
  16 samples while moving; settled bands reuse coefficients. We no longer interpolate
  numerator/denominator coefficients directly. Each intermediate design is valid.
- Unity preamp: no fixed whole-song attenuation derived from the maximum boost.
- Linked sample-peak protection at 0.98, instantaneous attack, **50 ms peak hold**
  and **200 ms recovery time constant**. Holding across bass cycles reduces the
  periodic gain recovery which modulated bass with the previous 80 ms release.
  The same envelope acts on all channels; no independent per-channel clipping.
- Protect the **wet signal before dry/wet mixing**. Off/Flat fades toward unchanged
  dry audio over 350 ms instead of leaving dry audio under the wet limiter and
  suddenly releasing it at the bypass boundary. Rapid reversals resume from the
  current mix. Settled Flat/off remains exact bypass.
- No lookahead delay line: no new stream timing offset for lyrics or music haptics.
  This is not a true-peak or loudness processor. Instantaneous peak catching can
  still cause transient distortion; holding can temporarily attenuate following
  content. Inter-sample peaks and physical headphone overload are not measured.
- Render code remains allocation-/lock-/sleep-/dispatch-free; control calculations
  are bounded. This does not establish worst-case iPhone CPU performance.

## Native AVAudioEngine / experimental decks
Use AVAudioUnitEQ plus Apple's downstream PeakLimiter. Explicit parameters:
attack **0.012 s** (the Apple default, no new attack-latency reduction), decay
**0.060 s**, pre-gain **0 dB**. Apple's header permits attack 0.001–0.03 s and
decay 0.001–0.06 s; the stream's 200 ms setting must NOT be copied to this AU.
Native limiter behavior is not asserted to be the portable C envelope or ceiling.
Small slider ramps now last at least 90 ms; toggle/route ramps remain at least
350 ms. Stale ramps are cancelled/generation-guarded. Limiters remain enabled
through return-to-flat transitions. Unsupported spatial/bitstream audio retains
honest passthrough; EQ does not force downloads or playback-engine replacement.

## UI and startup motion
The draggable control curve interpolates all ten gains using one SwiftUI animatable
vector (240 ms, no overshoot). Selection takes 180 ms. Direct graph/slider editing
is not delayed by these decorative animations. Reduce Motion disables interpolation.
Audio state is not driven by animation frames. Frame cadence is governed by iOS,
not an unconditional 120 fps guarantee.

A separate **“Суммарная АЧХ · модель PCM 48 кГц”** plot evaluates the exact C
coefficients on a logarithmic 20 Hz–20 kHz axis (±36 dB scale). It is a theoretical
small-signal cascade before dynamic protection, NOT a headphone measurement,
spectrum analyzer or exact model of Apple's native AU.

The existing brand launch sequence is accelerated uniformly from **3.5 s to 1.5 s**.
Visual and medium tactile events retain one shared clock; the opaque first-frame
cover, cold-start-only gate and immediate interruption behavior are unchanged.
Reduce Motion stays at 0.35 s. Root preparation still runs underneath the cover.

## Verification
`test_realtime_eq.py` compiles and executes the actual portable C source: independent
band/shelf response, unity preamp, sample-peak ceiling, channels/stereo isolation,
8/32/44.1/48/96 kHz, invalid controls, rapid changes, exact bypass and transitions.
New tests check response-plot agreement with rendered audio, harmonic distortion
on sustained bass, and disabling an actually limited signal without a boundary jump.

A reproducible synthetic measurement against parent `e166e9917a282d395055c2f30cf36fc510e72d59`:
40 Hz sine, 0.8 input amplitude (−1.94 dBFS), +12 dB low shelf; two seconds rendered,
DFT of final 0.5 seconds, harmonics 2–10 divided by fundamental. THD changes from
**1.8145% to 0.0797%**, with sample peak 0.98 in both cases. This is NOT THD+N,
real music/headphone listening validation or a general 22× improvement claim.

`test_eq_native_dsp.py` runs real AVAudioUnitEQ/PeakLimiter offline on macOS CI,
including low/middle/high centers, native limiter parameter readback, stereo and
hot-signal checks. Linux skips native Swift/AVFAudio tests rather than claiming
success. Existing tests retain saved presets/migrations and startup coverage.

Moderate boosts usually retain more dynamics. Unlimited bass, identical perceived
loudness and zero distortion cannot all be guaranteed under one output ceiling.
Real iPhone/headphone listening remains necessary at a sensible volume.

## References
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/bandwidth
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/gain
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq/globalgain
- https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap
- Apple AudioUnitParameters.h, AUPeakLimiter global parameter definitions.
