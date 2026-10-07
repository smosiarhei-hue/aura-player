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
Current rendering is visualization-only in one pass to the drawable. The glass optics and intermediate RGBA16F texture were removed at the owner’s request. Frame-constant directions and pigments are computed once on CPU.
It renders SDR premultiplied alpha to a transparent BGRA8 layer. “Dolby Vision” in the prototype comments is not a real HDR pipeline.
Desktop pointer drift is held at zero; the spotlight remains centered, as before any pointer movement.
Normal rendering requests the screen-supported refresh rate up to 120 Hz. Adaptive scale is 0.25–0.5 (starts at 0.35; DPR capped at 2). Low-power mode requests at most 30 Hz with scale up to 0.3.
Soft alpha feathering inside Metal blends into both themes; no extra blurred SwiftUI mask, glass panel, foreground blur or cover shaking.
Legacy MusicWave.metal remains unused; the home now renders BeatWaveMetalView.

## Audio and physics
Native existing decoded PCM is reused. The native 1024-sample FFT/log bands are retained, not replaced by a second Web Audio graph. Band endpoints/resolution therefore differ slightly from the browser's 2048 FFT.
Real PCM RMS is added to a portable feature snapshot. Capture timestamp is set in DSP, before MainActor publication.
Kick onset IDs stay monotonic across reset; a sustained bass note cannot repeatedly reinject a spring impulse.
The prototype's unstable Euler spring is replaced with the exact underdamped solution (m=1,k=130,c=15). The exact spring solution fixes FPS-dependent deformation. The later beat-response correction intentionally accelerates envelopes/flow and adds direct geometric impulse, as requested by the owner.
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


## Follow-up: visualization-only / ProMotion
The owner rejected the glass card/rim on device and reported heavy lag. The glass optics pass, offscreen scene texture and blurred SwiftUI mask have been removed entirely. The native field writes premultiplied alpha directly to the drawable; only its soft shader feather remains.
A single weak-target CADisplayLink now owns motion, haptics and GPU submission outside SwiftUI body/state updates. It requests the attached display's supported frequency, up to 120 Hz, uses common run-loop mode during scrolling, and invalidates on pause/hide/Reduce Motion/background/dismantle. Info.plist opts into high-refresh phone frames. Low-power mode requests at most 30 Hz.
Frame-constant strand directions and pigments are prepared once per frame on CPU, not recomputed for every pixel. Completed GPU timings adapt pixel resolution (0.25–0.5 render scale, DPR capped at 2) without changing musical phase, strand count or selected colors. The in-flight limit is nonblocking; buffers never accumulate without bound. This is support for ProMotion, not a measured guarantee of sustained 120 FPS on all devices. Device visual/GPU/thermal validation remains required.


## Follow-up: immediate beat reaction and lower pixel cost
Sparse native logarithmic FFT bands no longer attenuate sub/bass by averaging unpopulated slots: features use a populated-bin-weighted mean. The existing FFT/PCM/EQ paths are preserved.
Confirmed one-shot onset immediately sets the impact envelope, with a short release. A bounded radial expansion and travelling bend directly deform the field; foreground artwork/text are never transformed. Continuous audio-integrated flow uses a faster preset, and its additional 0.6 time multiplier is removed consistently from CPU strand colors/directions and Metal.
Noise evaluation is shared per pixel rather than performed for each rotated strand. The filament/halo/palette identity remains, but microturbulence is intentionally simplified to reduce GPU cost. With 14 active strands and two strand evaluations each, the former worst-case 87 octave-noise texture samples per pixel become at most 3 at normal quality (gate/culling can reduce the old count); this is a static work-count reduction, not a device FPS benchmark.
The local BEAT_WAVE diagnostic report records display-link ticks, submitted-frame rate, average GPU duration, busy drops, scale, feature age and estimated route delay every five seconds. Submitted-frame rate is not a measurement of displayed frames. Existing route-latency estimation is retained rather than removed without output-clock evidence. No external telemetry or automatic uploads are added.
CI tests cover sparse FFT bins at 44.1/48kHz, immediate impact/deformation, no duplicate impulse, sustained tone, silence, faster audio-driven flow, frame hitches, causal queue and stable spring across frame rates. Actual GPU/visual/haptic timing still requires the user's device.


## Apple lifecycle correction after continued on-device freezes
The previous explicit MTKView mode (`isPaused=true`, `enableSetNeedsDisplay=false`) drew directly from a CADisplayLink callback without calling `MTKView.draw()` or assigning its delegate. This bypassed MetalKit's per-frame drawable lifecycle. The correction keeps one main-run-loop CADisplayLink but calls `view.draw()` and renders only inside `MTKViewDelegate.draw(in:)`. MetalKit now owns its cached currentDrawable frame boundary. This API-contract defect is confirmed by inspection; it is not yet a measured explanation of every reported device hang.
CPU uniforms/strand data are prepared before late currentRenderPassDescriptor/currentDrawable acquisition; draw() and delegate rendering have autorelease pools. The nonblocking in-flight limit remains. There is no GPU completion wait on the main thread. Delegate teardown, weak display-link ownership, pause/scene/Reduce Motion gating and GPU error logging remain explicit. Swift 6 actor isolation is respected: the custom main-run-loop draw() invokes the @MainActor delegate; @preconcurrency adapts the SDK protocol, not permission for background UIKit access.

Authoritative Apple references consulted:
- https://developer.apple.com/documentation/metalkit/mtkview — explicit draw mode, draw(in:) delegate, acquisition and presentation.
- https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html — short drawable lifetime, autorelease pools and late acquisition.
- https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes — iOS 27 release notes, Metal fixes and new MetricKit frame-rate diagnostics. The listed clamp-to-edge sampler issue is not evidence for this repeat-addressed noise renderer's freeze.

No deployment target, audio session, player, EQ, streaming tap or shader style is changed for this lifecycle fix. No undocumented iOS 27 API is introduced, and no Xcode 27/SDK 27 validation is claimed unless the actual builder toolchain confirms it. Build success/source checks do not replace an on-device Metal validation/profiling session. The local BEAT_WAVE report is needed to quantify remaining GPU/CPU/presentation stalls.

## Slow in-place revision (owner feedback)

Fixed 14 wave axes and pigment: no orbit, atan2 core, animated strand count, travelling light packets or time-driven color/brightness gates. Only slow audio-integrated phase bends the waves in place (speed capped at 0.18). The real low-frequency envelope controls curvature and light; measured kick events share one critically damped m=1/k=64/c=16 recoil with haptics. Visual attack 25 ms/release 300 ms softens the previous sharp tick. Real PCM RMS gates logarithmic noise levels: silence cannot invent movement. Detector uses adaptive bass flux (160 ms refractory), not BPM.

Home background extends upward by the host's actual safe-area inset; its height grows by the same amount and its offset is the negative inset. Thus the lower boundary stays at the original hero bottom. Foreground layout is unchanged; background scrolls with My Wave, not Popular/Charts. Physical top feather is 1.5%; original physical lower feather remains 12% (the original vertex UV is bottom=0/top=1).

Output-latency alignment remains an estimate, not sample-accurate AirPods calibration. No new player, download, Dolby Vision/HDR pipeline or audio-session owner. Native rendering/sound alignment and top-safe-area behaviour require device validation; a Linux equation preview is not an iPhone measurement.

## Neural Float + artwork palette + native EDR revision

The owner rejected parallel lanes and explicitly selected `@reactbits-starter/neural-float-tw`. Public docs describe 12 paired neural filaments with spine/halo, segmented masks, turbulence, cold/hot colors and adaptive quality. This native adaptation restores those motifs from the owner-supplied ZIP, not a claimed authenticated npm install or a byte-identical copy of the proprietary registry. The registry requires a license key; no access controls were bypassed. Original archive attribution/provenance caveats still apply.

12 fixed angular strand pairs replace the previous parallel lanes. No time-driven orbit, swirl, packet train or guessed BPM returns. Spatial pulse/segment patterns shape the filaments; movement is slow audio-integrated deformation and light follows PCM bass/measured kick envelopes. Shared per-pixel noise and one render pass remain for performance.

The background now resolves the CURRENT decoded artwork via the existing cover cache, performs 32x32 sRGB dominant-color extraction on a utility task and rejects stale track results. A bounded 32-entry palette cache and 850 ms render-side interpolation avoid per-frame extraction/UI updates. Neutral artwork remains neutral; image padding cannot create a hue. Until an image is available, the track palette is only a fallback. Optional network request fetches the artwork URL only, never audio.

Actual Apple EDR output: optional rgba16Float pipeline, extendedLinearDisplayP3 CAMetalLayer colorspace and wantsExtendedDynamicRangeContent. Use the attached scene screen's potential/current EDR headroom, smoothly capped at 2.5. Output transforms sRGB-derived artwork hues into linear P3 and allows values above 1 only on the EDR path. Unsupported hardware/pipeline and Low Power Mode use bgra8Unorm SDR. Reduced HDR resolution ceiling bounds the added bandwidth. This is procedurally generated HDR/EDR highlights, NOT licensed/certified Dolby Vision, Dolby metadata, or recovered HDR detail in an SDR cover. Brightness/headroom/actual FPS must be measured on device.

Official references: https://pro.reactbits.dev/docs/components/neural-float ; https://pro.reactbits.dev/docs/installation ; https://developer.apple.com/videos/play/wwdc2022/10114/ ; https://developer.apple.com/documentation/uikit/uiscreen/currentedrheadroom ; https://developer.apple.com/documentation/uikit/uiscreen/potentialedrheadroom

### iOS colorspace API correction
Apple's WWDC22 sample also contains macOS-only MTKView.colorspace. iOS compilation correctly rejected it. Set CAMetalLayer.colorspace instead on iOS, keeping MTKView.colorPixelFormat and CAMetalLayer.wantsExtendedDynamicRangeContent. The regression suite forbids view.colorspace and requires layer.colorspace.

## Owner explicitly chose the supplied archive as implementation source

Archive SHA256 9feea4f0f625fe5618a7fd66767a40e0c434d2d2643e1c9a3793fd2747489799. Restore per-strand `turbulence(q*4+t*0.4)` rather than the invented shared-flow/sinusoidal substitute. Slow archive segment/pulse carriers follow music-integrated phase. Use the archive's 14 pairs with fixed directions/count, retain no glass/orbit/swirl/packet train/white pearlescent glint. Therefore this is a deliberate native archive adaptation, NOT the paid official registry component nor an unchanged ZIP.

Octave noise is baked once into RGB (3/2/1 octaves) using the archive hash, Hermite texture and texel-centre-correct repeat/bilinear samples. Native shader reads it once per strand: per-strand curvature returns without 3 separate octave reads every frame. Grid-point regression tolerance is half one RGBA8 quantization step; off-grid filtered LUT is an approximation, not bit-identical filtering. Geometry/feather stays separate from adaptive pixel resolution.

A bounded kick displacement and musical gain after tone compression keep the actual onset visible. Reduce the overlapping plasma core, keep palette/EDR, single-pass rendering, no blur postprocess and no playback/EQ/download changes. Route alignment is still an estimate, not a phone/AirPods measurement.

## Sample/media-clock alignment revision

Previously the C tap discarded MTAudioProcessingTapGetSourceAudio's timeRangeOut, the DSP stamped the window with polling time, the polling interval was 25 ms and renderer added a generic route delay. This is not sample-time synchronization.

The C tap now retains asset time of the latest 1024-sample window CENTRE (Hann FFT), clears capture across seeks/gaps, and exposes an additive timed reader; the old reader API remains compatible. PCM/EQ processing and nonblocking capture locks are unchanged. Swift preserves source media time; kick detector intervals use media time. Renderer selects due features using the audible AVPlayerItem.currentTime() and rate, with CADisplayLink.targetTimestamp lead for the upcoming frame. It does not apply a second guessed output delay on this media-clock branch. Polling is 8 ms, but retained source timestamps—not polling timestamps—schedule media features. Paused/buffering clocks cannot manufacture an advancing beat.

Local engine tap uses AVAudioTime.hostTime plus the centre of the first 1024 samples. Snapshot observedAt guards reset races independently of sample capturedAt. Seek/reset clears pending features; media queue is bounded to 256 items. First due kick bypasses visual attack smoothing; damped recoil/slow flow and all graphics/palette/EDR remain unchanged. Local clock fallback still uses an output-delay estimate. Logs distinguish clock=media/capture and record feature age and next-display lead.

Remaining limitations: the C capture still exposes the latest window, not a lossless every-hop feature queue; unavailable timestamps fall back to capture timing. A finite FFT window, onset classification, frame duration, GPU presentation and physical Bluetooth/haptic latency prevent a zero-millisecond guarantee. Arrival-jitter tests validate predecoded media features arriving before their deadline, not acoustic timing on a real iPhone/AirPods. Device measurement is still required.

Apple references: https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtapgetsourceaudio(_:_:_:_:_:_:) ; https://developer.apple.com/documentation/quartzcore/cadisplaylink ; https://developer.apple.com/documentation/avfoundation/avplayeritem/currenttime()

Yandex API resolves the stream URL into the existing AVPlayer deck; this same decoded-PCM/media-clock path applies to Yandex streaming tracks. Waiting/paused AVPlayer states report zero presentation rate, so future beat features are not consumed during buffering. No extra track download or second audio engine is introduced. Protected streams without accessible PCM retain the existing unavailable-analysis fallback.

## Continuous stream onsets and larger parallel flow (supersedes radial weave above)

User-requested visual change: 24 parallel curved filaments with one fixed orientation, a 1.25x spatial enlargement, and bounded shared translation driven only by the music-integrated phase. No global orbit, central stationary blob, per-strand random gate, crossed second strand, glass pass or additional blur pass. Cover palette, premultiplied alpha, EDR/SDR output, top safe-area extension and original lower hero boundary remain unchanged. This is an owner-requested adaptation of the archive's filament spine/halo, not a claim of copying licensed ReactBits Pro source.

`PCMWindowQueue.h` is the actual portable C11 capture used by `MTAudioProcessingTap`: 1024 samples, 256-sample hop, 256 preallocated windows (~1 MiB/deck). A large decoded callback now contributes every complete overlapping window, including attacks before its last 1024 samples. SPSC release/acquire indices keep producer slots protected from a concurrent consumer; no audio-thread mutex, allocation, UI read lock or FFT. A seek/discontinuity increments an epoch, and readers discard obsolete windows. Overflow drops newly produced windows, counts them and logs `PCM queue dropped windows=`; bounded capture is NOT a promise of losslessness under arbitrary decode-ahead or CPU overload.

The active deck drains at most 16 windows/poll; two reserved analysis slots bound worker backlog. Accelerate FFT runs on a serial user-initiated worker for stream windows, rather than the main/UI thread. Every feature is delivered even when meter updates are throttled. The renderer consumes chronological features at the existing native media/display deadline; read/decode-ahead bursts do not clear valid future features solely because no new callback arrived for 0.5 s.

`BeatWaveSpectralFlux` computes positive changes of individual raw, log-compressed FFT bins, with low band 30–180 Hz and attack band 180–2000 Hz. The detector uses prior time-bounded statistics, a short refractory interval, low-frequency presence and PCM energy. This detects onsets, not a guaranteed instrument-separated kick or universal musical beat grid. Sustained bass is not a recurring event. No guessed BPM, microphone, extra AVPlayer/engine or full-file download was added; Yandex streaming continues through the same resolved URL, audible AVPlayerItem and tap. Protected/unsupported PCM retains the existing unavailable-analysis behavior.

Verification: native portable-C tests cover large callbacks, arbitrary callback boundaries, sample-centre timestamps, seek epochs, finite sample sanitization, bounded overflow, and concurrent producer/consumer slot integrity. Pure Swift CI checks raw-bin flux and sustained-input stability. Locally rendered SDR reference frames check composition and separation of the parallel filaments; they are mathematical previews, not a Metal/iPhone performance test. Real headphone delay, subjective rhythm perception, route latency and displayed FPS still require on-device testing.

Research references (not new dependencies):
- https://developer.apple.com/documentation/MediaToolbox/MTAudioProcessingTap
- https://developer.apple.com/streaming/Whats-new-HLS.pdf (2026 HLS mix tap and decoded-output API; newer symbols are not unconditionally introduced into the existing SDK/deployment target)
- https://github.com/ryanfrancesconi/spfk-tempo (multi-band spectral flux and overlapping streaming frames; package not installed and no second decoding pipeline)
