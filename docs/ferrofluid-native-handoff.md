# Ferrofluid native visual handoff

Owner selected option 1 (React Bits Ferrofluid) and explicitly authorized replacing only obsolete visual tests. Audio, EQ, beat detection, causal presentation, queue limits, decay, flow-speed integration and haptics are unchanged from `04fccec`.

## Source and license
- Upstream: https://github.com/DavidHDev/react-bits/blob/63a008de65732d73010bd219d25d15c47739bb31/src/ts-default/Backgrounds/Ferrofluid/Ferrofluid.tsx
- Live reference: https://reactbits.dev/backgrounds/ferrofluid
- Copyright 2026 David Haz, MIT + Commons Clause. Full notice: `docs/licenses/react-bits-ferrofluid-LICENSE.md`.
- Integrated as part of Sonivo, not redistributed as a standalone component library. No React, OGL or other runtime dependency is added.

## Native adaptation
Upstream hash, sine-interpolated value noise, five-offset weighted domain blend, smooth minimum and rim/shimmer lighting are translated to Metal. GLSL modulo is implemented with floor semantics for negative coordinates. Upstream scale 1.6, fluidity 0.1 and downward flow are retained. Owner-requested visibility tuning uses sharpness 1.8 (was 2.5), shimmer suppression 1.05 (was 1.5) and glow 3 (was 2). This reveals more of the existing rims at identical field coordinates, without changing motion, kick mapping, sampling cost or adding a blur pass. No mouse interaction or independent wall-clock animation.

The existing `motion.phase` is the only flow clock (slow music-energy-integrated motion). Existing causal impact widens the rim by at most 0.055; existing spring offsets the threshold by at most 0.012. Bass energy influences luminosity, not detection. Three artwork colors interpolate continuously to avoid hard color seams. Coverage derives from rim luminance rather than palette brightness, so dark artwork does not doubly attenuate the effect. Tone compression and original edge feathering preserve UI legibility and the lower boundary. This is an audio-adapted native port, not a pixel-identical recording of the web demo.

## Rendering and limits
One fragment pass directly into the transparent drawable; no simulation history, raymarch, postprocessing blur, extra glass frame or always-red cover halo. Removed the obsolete 32-entry strand upload and 512x512 noise texture from the renderer. SDR/linear-P3 EDR output, hardware fallback, adaptive render scale, GPU completion diagnostics, display-link lifecycle and supported refresh request remain unchanged. EDR is not Dolby Vision certification; a 120 Hz request is not measured 120 fps.

Linux structural/portable tests and macOS compilation cannot establish real-device audio synchronization, GPU frame time, thermal behavior or perceived color. Verify on iPhone with streaming music, pause/seek, changing artwork, light/dark themes, Reduce Motion, low-power mode and 120/140 BPM measurement tracks before approving performance or synchronization.


## Bass/kick highlight update
The bright rims receive localized gain (up to 1.85 before existing SDR tone compression) from bass and kick only. A cosmetic display-link envelope uses 20/18 ms attack and 240/220 ms release for bass/kick respectively. It runs after existing audio presentation/motion and does not feed back into detection, causal queue, speed, spring, EQ or haptics. Reset on stop, unavailable capture and timeline discontinuity prevents stale glow. This intentionally softens lighting onset; it is not a promise of zero-latency visible peak.

Uniform ABI is unchanged: previously reserved `resolution.zw` carry these light envelopes. The shader raises highlights, not the entire frame. A shared exponential SDR shoulder preserves hue and gradients instead of per-channel clipping or flat saturated patches. Linear-P3 EDR highlights use 35–100% of the existing hardware-reported headroom according to the light envelope and only for already bright pixels. Existing headroom cap/fallback, single Metal pass and render budget are unchanged. Not Apple Vision/Dolby Vision certification. Verify actual HDR appearance, sync and frame time on the device; browser SDR previews cannot prove HDR luminance.
