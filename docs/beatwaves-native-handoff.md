# Beat Waves native handoff

Owner confirmed the uploaded prototype's visual direction in chat with “да”.
Source: `sonivo-beatwaves-prototype-handoff.zip`, SHA-256 `9feea4f0f625fe5618a7fd66767a40e0c434d2d2643e1c9a3793fd2747489799`.
Fresh application baseline: `d54000bea67b9c0f14b318fa9977cc6ee1be25f1`.

## Scope
Only the existing scrolling My Wave hero. Its visibility callback and theme remain unchanged.
No React, WebView, extra AVPlayer/AVAudioEngine, new song downloads, EQ, volume or queue changes.
The supplied demo UI/artwork/copy are not migrated. The existing cover and controls remain stable.

## Visual fidelity and deliberate corrections
`BeatWave.metal` ports the supplied GLSL strand, pulse, noise, plasma and glass math using the final Sonivo palette/settings.
The expensive field is evaluated once into RGBA16F; the optics pass samples that texture seven times instead of rerunning the field seven times. Small resampling differences vs analytic GLSL evaluation are expected.
It renders SDR premultiplied alpha to a transparent BGRA8 layer. “Dolby Vision” in the prototype comments is not a real HDR pipeline.
Desktop pointer drift is held at zero; the spotlight remains centered, as before any pointer movement.
Normal rendering is capped at 30 FPS / half scale (DPR capped at 2); low-power mode uses 20 FPS / 0.35 scale.
A soft external hero mask blends into both themes. No foreground blur or cover shaking.
Legacy MusicWave.metal remains unused; the home now renders BeatWaveMetalView.

## Audio and physics
Native existing decoded PCM is reused. The native 1024-sample FFT/log bands are retained, not replaced by a second Web Audio graph. Band endpoints/resolution therefore differ slightly from the browser's 2048 FFT.
Real PCM RMS is added to a portable feature snapshot. Capture timestamp is set in DSP, before MainActor publication.
Kick onset IDs stay monotonic across reset; a sustained bass note cannot repeatedly reinject a spring impulse.
The prototype's unstable Euler spring is replaced with the exact underdamped solution (m=1,k=130,c=15). Envelopes, speed and final preset parameters are preserved; the resulting spring trajectory intentionally fixes FPS-dependent deformation.
The bounded causal queue uses the system route-reported outputLatency + ioBufferDuration estimate. It does not predict future audio or claim measured AirPods synchronization.
First activation consumes the current event ID to avoid replaying a past kick. Pause/hide/scene suspension/Reduce Motion clear pending presentation state and stop frame scheduling. Missing PCM settles rather than invents a tempo.

## Haptics
The existing Core Haptics engine is reused. While the hero runs, its one-shot kick event also drives the existing opt-in `settings.musicHaptics` intensity; the old independent raw-band haptic path is suppressed to avoid competing patterns. No output delay is added twice.
Each event has a capped transient plus a 55ms soft body; onset refractory interval is 130ms. Hardware capability checks remain in the engine. This is vibration on the phone, not AirPods vibration.

## Provenance caveat
The owner-supplied archive calls its source “React Bits Pro Neural Float” and “WindowsLiquidGlass” but supplies no upstream revision or license. These labels are preserved here as provenance claims, not verified licensing or technology claims. No MIT/free-use license is inferred. Confirm rights before redistribution or release beyond the owner's personal testing.

## Validation
Browser source: npm ci --ignore-scripts, 20/20 tests, production build passed during inspection.
Native CI includes an actual Swift executable testing onset, sustained tone, silence, seek IDs, one-shot impulse, invalid inputs, stable spring at 10/20/30/60/120 FPS and causal presentation/reset. Linux source guards are not a substitute for Swift/Metal compilation.
Build IPA must complete before delivery. Device visual comparison, GPU frame-time/power measurement, listening and iPhone/AirPods timing remain required. No such device test has been performed by this port.
