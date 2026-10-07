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

## Bass profiles and EQ screen (v3)

The screen now uses native, half-decibel horizontal sliders in three regions (low/mid/high), with per-band reset, large touch targets, VoiceOver values, adaptive text layouts and semantic light/dark surfaces. Factory profiles are chosen explicitly. The old factory bass curves are upgraded once; arbitrary custom curves are kept. Selecting a profile turns EQ on; switching EQ off does not discard it or change iPhone volume.

- AirPods Pro 2 taste profile: `[6, 4.5, 1.5, -1, -0.5, 0, 0, 0, 0, 0]` dB.
- Deep bass: `[8, 6, 2, -2, -1, 0, 0, 0, 0, 0]` dB.

The lower shelf affects frequencies below 31.25 Hz, including the sub-bass region; 62.5 Hz adds kick weight, and 125 Hz controls density. Reducing 250–500 Hz avoids confusing low-mid boom with deeper bass. Full-cascade headroom and channel-linked protection remain active. No fabricated subharmonics, bass clipping, automatic phone-volume increase or Bluetooth/HFP route changes are introduced.

Apple's [AirPods Pro 2 specifications](https://support.apple.com/en-us/111851) describe the high-excursion driver, amplifier, Adaptive EQ and spatial audio, but do not publish a numerical lowest frequency or fixed EQ bands. This app profile is not an Apple-certified calibration. Apple's [ear-tip guidance](https://support.apple.com/en-md/119849) explicitly links a good acoustic seal with rich bass. The physical result depends on the recording, seal, firmware/system processing and listening level.

Tests exercise both actual preset curves at 20/63/250/500 Hz and check bounded output on a high-level multitone. Layout prototypes were visually inspected at 375px in light/dark, enlarged text/reduced motion, and 812px landscape. These are layout checks, not native iOS simulator screenshots; device listening and native Dynamic Type/VoiceOver testing are still needed.

## Mini-player buffer semantics

`loadedTimeRanges` only gives the buffered portion of online playback, not a saved-track download. The main timeline can show this as a subtle buffered range. The mini-player keeps the artist and playback progress during normal playback/prefetch; it never calls a buffered percentage “track download”. A delayed, cancellable 600ms label shows “Buffering” only while the audible AVPlayer is waiting, or “Connecting” during command setup. Pause and skip stay available. KVO follows `timeControlStatus`, never the preloaded deck or the percentage of the song in memory, and is rebuilt on media-services reset.
