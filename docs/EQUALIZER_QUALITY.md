# Equalizer: low / middle / high

## Audit scope
Audited the EQ control path, persisted gains/presets/migrations, local AVAudioEngine,
streamed PCM tap, route restrictions and the existing experimental DualDeck engines.
This is not a claim that every unrelated feature in the repository was reviewed.
No change to playback queues, Yandex requests, volume controls, icon selection,
launch animation or music haptics. AutoMix/Neuro engine switches remain disabled.

## Controls and Apple API
- Ten real filters: 30 / 60 / 120 / 250 / 500 / 1k / 2k / 4k / 8k / 15k Hz.
- Low: bands 0–3; middle: 4–6; high: 7–9. Category selection only selects a band;
  it never averages, resets or reshapes the user's curve. All ten controls remain
  visible, with native sliders and the accessible alternative layout.
- First/last filters are low/high shelves; interior bands are parametric with
  one-octave bandwidth. Centers are capped at 0.44 × the processing sample rate.
- Apple documents `bandwidth` in octaves (0.05–5), band/global gain −96…+24 dB.
  These are API limits, NOT recommended listening levels. App limits stay
  −12…+18 dB for bass and −12…+12 dB above bass, retaining saved user settings.
- The graph shows control gains, not a measured, summed frequency response.

Official documentation consulted:
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/bandwidth
- https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/gain
- https://developer.apple.com/documentation/avfaudio/avaudiouniteq/globalgain
- https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap

## Processing changes
The previous implementation explicitly disabled both preamp attenuation and peak
protection. Boosted neighboring bands can sum well above the largest slider gain.

The control thread now scans the cascaded RBJ response (1024 logarithmic points
plus DC/Nyquist), reserves the peak boost plus 1 dB, bounded to −48…0 dB. Both
portable C and the independent Swift package implementation use this estimate.
AVAudioUnitEQ's internal coefficients are not specified to be bit-identical to
RBJ; the estimate alone is NOT a guarantee against every native/transient peak.

Stream processing therefore also uses a linked sample-peak safety envelope:
0.98 ceiling, instantaneous attenuation, 80 ms release, one gain for all channels.
It is NOT true-peak, a mastering limiter, a lookahead limiter or loudness leveling.
Headroom reduces routine limiter activity; very hot inputs/transients can still
trigger gain reduction. No per-channel hard clipping or stereo crossmixing.

Native local audio keeps the existing Apple PeakLimiter node and enables it while
non-flat EQ/transition offsets are active (including the return-to-flat ramp).
DualDeck gets the same Apple unit after user EQ. Native limiter behavior/ceiling
is Apple's implementation, not asserted to equal the C 0.98 ceiling.

- Band changes ramp over 40 ms; stream coefficients/wet state are smoothed.
- Headroom attenuation is applied before raising filters; level recovery ramps.
- Flat/off steady states bypass DSP/protection and do not alter the signal.
- Experimental engines receive changes only if instantiated; no hidden engine
  startup. New engine boot applies the headphones-only route policy as well.
- Latest native package ramp generation wins over obsolete slider updates.
- Stream DSP is allocation-/lock-/sleep-/dispatch-free in its render callback;
  response scans run on the control path, not the audio render thread.
- Unsupported/spatial bitstreams retain existing honest passthrough behavior.
  No claim that a decoded-PCM tap can process every possible transport/format.

## Verification and limitations
`test_realtime_eq.py` compiles/runs the actual C source: center/shelf response,
overlapping boosts, high-level sweeps, impulses, rapid changes, planar/interleaved
8-channel isolation, stereo ratios, 8/32/44.1/48/96 kHz, invalid controls, exact
flat/off bypass and transition continuity.
`test_eq_native_dsp.py` additionally runs AVAudioUnitEQ and Apple's PeakLimiter
with AVAudioEngine offline rendering on macOS CI (real native filters, not a
Python reproduction). Linux skips that native test, never reports it as passed.
Existing Swift fixtures retain persistence, backup/migration and preset coverage.

CI/offline rendering is not listening validation, real-time performance validation
on an iPhone, headphone calibration or a proof of artifact-free sound for all
material. Check quiet speech, bass-heavy tracks, route changes and maximum boosts
on real hardware at a sensible listening volume. Bluetooth latency and hardware
speaker/headphone limits cannot be fixed by an app EQ. Boosting may lower overall
level to preserve headroom; system volume and system safety limits are untouched.
