# System Spatial Audio and unity playback level

## Audit and scope

Sonivo does not contain an HRTF/binaural renderer, AVAudioEnvironmentNode, or a general stereo widening/pan effect. System spatialization stays with AVPlayerItem.allowedAudioSpatializationFormats and the playback audio session. Fixed/head-tracked mode and the personalized profile remain system/user choices, not app-made effects.

Removed unused legacy AVAudioUnitReverb nodes, their preset loader, and the hall graph connections (they had wetDryMix=0). EQ now connects directly to the master mixer. The dormant alternate planner no longer generates Space Reverb events; its old serialized reverbWash case is retained for decoding compatibility but cannot enable a room effect. Other explicit musical transition features (tempo, filters, echo), EQ, and optional karaoke are not disguised as Spatial Audio and are not removed.

`isSpatialAudioEnabled` on the output port is treated as a capability, not proof of active rendering/head tracking. Removed codec-string-inferred Atmos/active Atmos badges. UI and logs describe permission/capability only. AC3/E-AC3 stream bypass stays intact; no conversion solely to apply EQ. Deployment target is unchanged; no iOS 27-only symbols added.

## Loudness audit and changes

Existing EQ preamp was already unity (0 dB) and the streamHeadroomCeiling was already 1.0. These were **not** proven causes of quieter steady-state listening. The audit found:

- Shared writable app gain used both by the shake/wave fader and sleep fade. A fade could capture another fade's attenuated level and restore it; stale completions could write into newer requests.
- Live legacy crossfade used linear 1-p/p amplitudes: at midpoint, unrelated streams had half their original summed power (approximately −3 dB).
- Dormant AutoMix planner enabled LUFS normalization by default (not the currently selected playback owner).
- Dormant alternate engine bridge could apply vocal DSP twice, through render notify and the master observation tap, when explicitly enabled.

Now `PlaybackGainState` independently owns wave and sleep envelopes with UUID tokens. Read-only master gain is exactly 1 outside these intentional fades, cannot inherit device volume or persist an attenuated baseline, and stale tokens cannot update or finish a newer fade. Changing track, stop, pause and media reset invalidate old wave envelopes. The wave callback renews its envelope for the switched track, and an older waiting callback cannot reclaim ownership from a newer fader. Active and incoming stream lanes both receive the envelope; native gain is applied once at the master.

Legacy crossfade uses the existing equal-power curve. This preserves summed power for unrelated signals; it does not promise constant perceived loudness for differently mastered songs or no summed peaks for correlated material. Normal completion/cancellation leaves the foreground deck at 1. Native playback resumes without stale per-deck attenuation. Dormant planner defaults to original loudness/no LUFS adjustment; explicit library requests for normalization remain supported. Alternate master observation tap is now read-only spectrum capture; optional vocal DSP has one owner.

Device output volume remains controlled by MPVolumeView and AVAudioSession.outputVolume. No automatic maximum-volume write, private API, headphone safety bypass, loudness booster, or new limiter was added. User EQ settings, previous app limiter choice, audio quality selection, video mute and haptics are unchanged. iOS or the accessory may apply its own processing/limits; the app cannot guarantee identical perceived loudness to a differently configured other player.

## Validation

- Actual portable C EQ bypass/channel/format/level tests remain green.
- Native Swift fixture compiles actual PlaybackGainState, production wave fader (AV/UI dependencies replaced only by a test player), CrossfadeCurve and MixSettings. Exercises unity, independent envelopes, stale tokens, NaN/range rejection, cancellation, awaited callback overlap, sleep coexistence and constant-power mathematics.
- Source guards check direct graph wiring, no room FX generation, no false active/Atmos inference, original-loudness defaults and no duplicate vocal processing.
- iOS archive is validated in the existing macOS Build IPA workflow. No physical AirPods listening or head tracking is claimed by CI. Compare the same source at the same device volume with EQ flat/off, karaoke off and the same Control Center Spatial Audio mode; then test route changes, pause/resume, wave switch and sleep cancellation.

Apple references: [spatialization preference](https://developer.apple.com/documentation/avfoundation/avplayeritem/allowedaudiospatializationformats), [port capability](https://developer.apple.com/documentation/avfaudio/avaudiosessionportdescription/isspatialaudioenabled), [user controls](https://support.apple.com/en-us/102469).
