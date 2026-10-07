# Ferrofluid native visual handoff

Owner selected option 1 (React Bits Ferrofluid) and explicitly authorized replacing only obsolete visual tests. Audio, EQ, beat detection, causal presentation, queue limits, decay, flow-speed integration and haptics are unchanged from `04fccec`.

## Source and license
- Upstream: https://github.com/DavidHDev/react-bits/blob/63a008de65732d73010bd219d25d15c47739bb31/src/ts-default/Backgrounds/Ferrofluid/Ferrofluid.tsx
- Live reference: https://reactbits.dev/backgrounds/ferrofluid
- Copyright 2026 David Haz, MIT + Commons Clause. Full notice: `docs/licenses/react-bits-ferrofluid-LICENSE.md`.
- Integrated as part of Sonivo, not redistributed as a standalone component library. No React, OGL or other runtime dependency is added.

## Native adaptation
Upstream hash, sine-interpolated value noise, five-offset weighted domain blend, smooth minimum and rim/shimmer lighting are translated to Metal. GLSL modulo is implemented with floor semantics for negative coordinates. Default scale 1.6, fluidity 0.1, sharpness 2.5, shimmer 1.5, glow 2 and downward flow are retained. No mouse interaction or independent wall-clock animation.

The existing `motion.phase` is the only flow clock (slow music-energy-integrated motion). Existing causal impact widens the rim by at most 0.055; existing spring offsets the threshold by at most 0.012. Bass energy influences luminosity, not detection. Three artwork colors interpolate continuously to avoid hard color seams. Coverage derives from rim luminance rather than palette brightness, so dark artwork does not doubly attenuate the effect. Tone compression and original edge feathering preserve UI legibility and the lower boundary. This is an audio-adapted native port, not a pixel-identical recording of the web demo.

## Rendering and limits
One fragment pass directly into the transparent drawable; no simulation history, raymarch, postprocessing blur, extra glass frame or always-red cover halo. Removed the obsolete 32-entry strand upload and 512x512 noise texture from the renderer. SDR/linear-P3 EDR output, hardware fallback, adaptive render scale, GPU completion diagnostics, display-link lifecycle and supported refresh request remain unchanged. EDR is not Dolby Vision certification; a 120 Hz request is not measured 120 fps.

Linux structural/portable tests and macOS compilation cannot establish real-device audio synchronization, GPU frame time, thermal behavior or perceived color. Verify on iPhone with streaming music, pause/seek, changing artwork, light/dark themes, Reduce Motion, low-power mode and 120/140 BPM measurement tracks before approving performance or synchronization.
