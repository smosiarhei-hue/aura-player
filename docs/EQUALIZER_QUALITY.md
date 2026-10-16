# Equalizer: low / middle / high

## Audit scope
Audited the EQ control path, persisted gains/presets/migrations, local AVAudioEngine,
streamed PCM tap, route restrictions and the existing experimental DualDeck engines.
This is not a claim that every unrelated feature in the repository was reviewed.
No change to playback queues, Yandex requests, volume controls, icon selection,
launch animation or music haptics. AutoMix/Neuro engine switches remain disabled.

## Controls and Apple API
- Ten real filters: 40 / 60 / 120 / 250 / 500 / 1k / 2k / 4k / 8k / 15k Hz.
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

## Current level policy (user-requested revision)

Static headroom attenuation was rejected after listening feedback: a +18 dB
manual bass curve made the rest of the song much quieter, and returning to dry
sound restored a large amount of level too quickly. The current policy keeps
**unity preamp (0 dB)** in both native and streamed paths, irrespective of boosts.
It does not change iPhone system volume or apply another fixed playback gain.

Protection is based on actual peaks instead of subtracting the maximum boost:
- Stream: linked sample-peak envelope, 0.98 ceiling, instantaneous attenuation,
  80 ms release, same gain for all channels. No per-channel hard clipping.
- Local/DualDeck: downstream Apple PeakLimiter, enabled for non-flat EQ and
  kept active through transitions. Its implementation/ceiling is Apple's, not
  asserted to equal the portable C 0.98 ceiling.
- This is NOT true-peak, loudness normalization, headphone calibration or a
  promise of identical perceived loudness with arbitrary EQ settings.
- Strong boosts can engage limiting frequently and reduce perceived dynamics or
  the level of other frequencies. Unlimited bass, unchanged loudness and zero
  distortion cannot all be guaranteed within the same digital/output ceiling.

Stream toggles crossfade the complete protected EQ output to/from dry audio with
an eased 350 ms transition at unity preamp. They do NOT combine an instant return
to identity filters with a fast release of a large negative preamp. Rapid reversals
resume from the current wet mix. Stable Flat/off remains exact bypass.
Native toggle/route ramps are eased and at least 350 ms; obsolete ramps are
cancelled/generation-guarded. Ordinary small slider moves retain shorter ramps.

The lowest shelf center is now **40 Hz**, not a cosmetic relabeling of 30 Hz.
The stored compact ten-slider curve keeps every gain at the same index. Saved
presets carrying the previous 30 Hz compact frequency metadata are recognized,
backed up and migrated without reshaping gains or changing IDs/names. Truly
historical 10/29-band layouts still use their original source grids/migration.

Experimental engines receive EQ only if already instantiated, respecting the
headphones-only policy; no engine is secretly enabled or started. Unsupported
spatial/bitstream formats keep the existing honest passthrough behavior.
Stream render code remains allocation-/lock-/sleep-/dispatch-free.

## Verification and limitations
`test_realtime_eq.py` compiles/runs the actual C source: center/shelf response,
unity preamp/unaffected midrange, high-level sweeps, impulses, rapid changes, planar/interleaved
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
speaker/headphone limits cannot be fixed by an app EQ. Peak limiting can reduce level during overload; there is no fixed preamp cut.
System volume and system safety limits are untouched.
