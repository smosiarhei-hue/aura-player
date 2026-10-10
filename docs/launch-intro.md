# Native Sonivo launch intro

A 1.85-second SwiftUI brand reveal after the static iOS launch screen. Five warm-accent sound bars assemble, six rounded wordmark letters reveal in a 40 ms stagger, and the scene crossfades into the already-mounted app. No streamed assets, video player, imported fonts, new packages or audio samples are used.

RootView is created immediately, so startup work is not postponed until the reveal ends. The in-memory launch session plays once per host lifetime, not whenever the scene resumes. A visible, accessible Skip action completes it immediately. Backgrounding, disappearance, external playback openings and playback starting stop the haptics and finish the intro. Existing RootView deep-link handlers remain responsible for opening the player.

Reduced Motion shows the complete static brand for 0.35 seconds with a short opacity transition, no spatial choreography and no scheduled tactile pattern. Devices without haptic support or with app control haptics disabled still show the visual reveal. CoreHaptics failures fall back to visual-only playback.

## Tactile timing

Two gentle haptic-only transients use the shared `SonivoLaunchMotion` timeline at 0.48 and 0.82 seconds (strengths 0.45 and 0.22). The visual epoch and the haptic engine are both scheduled with a 35 ms lead. Stop/skip cancels queued events. No music haptics override, audio-session configuration change or fabricated beat detector input is introduced.

This is bounded launch choreography, not a promise of measured frame rate or sample-accurate synchronization on a physical device. SwiftUI chooses the display cadence; actual smoothness and Taptic feel require an iPhone test.

## Checks

The compiled Swift check executes the real timing/lifetime model: one-shot startup, inactive scenes, playback bypass, early skip, monotonic letter reveal, fade completion, finite input handling and time-based behavior at 30/60/120 sampling rates. Structural tests verify immediate root mounting, cancellation hooks, existing deep-link routing, no video/network startup dependency, accessibility and common haptic/visual timing. Final app compilation validates the SwiftUI/CoreHaptics integration on macOS.

## Reference

https://prompt-motion.com/jesscaroline7-1ff7cb — kinetic typography / app-motion reel used for direction only. Its video, artwork and code were not copied. Sonivo's native vectors and wordmark are original implementation.
