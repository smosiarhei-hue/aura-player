# Realtime EQ and system spatial playback

## Signal paths

- Online: Apple's decoder → C MTAudioProcessingTap PCM EQ → AVPlayer/system headphone spatialization. EQ never downloads a complete song, creates a second player, or migrates playback to AVAudioEngine.
- Local: existing player nodes → time-pitch (bypassed at normal speed) → AVAudioUnitEQ → reverb (dry by default) → mixer → one vocal processing render notify → Apple peak limiter → output.
- The spectrum observer only reads audio. It must not run the stateful vocal processor again.
- One settings owner publishes the same enabled/headphone-route state and ten gains to both paths. New online taps receive that state before their audio mix is installed.

## DSP

Ten octave bands: 31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz. Edge bands are shelves, inner bands one-octave parametric filters. Saved legacy curves are interpolated in log-frequency space once, not discarded. Presets use moderate boosts.

The C renderer keeps independent double-precision state for up to eight Float32 PCM channels, planar or interleaved. It never crossfeeds/downmixes the output. Full-cascade response estimation adds headroom for overlapping boosts; linked peak protection retains channel balance. Coefficients and dry/wet/gain changes are smoothed. Flat or fully disabled EQ is an exact PCM bypass. Control values use an atomic mailbox, with no render-thread allocation, Swift callbacks, network work or waiting for UI locks.

Local AU settings ramp over 40 ms. Both paths retain the user's EQ when switching tracks/routes, without resetting gains. Turning off EQ restores the original curve rather than boosting loudness.

## Spatial audio and limitations

The audio session is playback/default, not moviePlayback and not a microphone/HFP session. iOS handles compatible headphone spatialization and head tracking. The app does not add a second pseudo-surround effect or claim that ordinary stereo/E-AC-3 is Dolby Atmos.

Encoded AC-3/E-AC-3 stays on the unmodified system path; no custom audio mix is installed merely to apply EQ. Protected/live/unsupported assets may not expose editable PCM. Their original sound continues and the EQ UI reports that limitation, rather than downloading them or pretending EQ is active. Network startup buffering is still necessary for online music; EQ has no separate full-track download or network dependency.

## Validation

`python3 -m unittest discover -s .github/scripts -p 'test_*.py'`

`test_realtime_eq.py` compiles the actual C DSP and tests exact bypass, requested frequency gain, shelves, full-cascade headroom, 8-channel independence, planar/interleaved layouts, linked limiting, invalid values, multiple sample rates and live slider/toggle transitions. Structural regression checks cover no EQ downloads, no duplicate vocal processing, native limiter wiring and spatial passthrough.

Device listening remains necessary: compare EQ off/flat/preset, toggle during playback, seek/skip/crossfade, and switch speaker/wired/Bluetooth/AirPods. In Control Center compare spatial audio off/fixed/head-tracked. Test mono/stereo and authentic Dolby sources separately. CI cannot verify headphone acoustics or head tracking.
