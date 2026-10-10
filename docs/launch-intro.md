# Native Sonivo launch intro

A 3.25-second SwiftUI brand reveal after the static iOS launch screen. Five warm-accent sound bars assemble, six rounded wordmark letters reveal in a 60 ms stagger, and the scene crossfades into the already-mounted app. No streamed assets, video player, imported fonts, new packages or audio samples are used.

RootView is created immediately, so startup work is not postponed until the reveal ends. The in-memory launch session plays once per host lifetime, not whenever the scene resumes. A visible, accessible Skip action completes it immediately. Backgrounding, disappearance, external playback openings and playback starting stop the haptics and finish the intro. Existing RootView deep-link handlers remain responsible for opening the player.

Reduced Motion shows the complete static brand for 0.35 seconds with a short opacity transition, no spatial choreography and no scheduled tactile pattern. Devices without haptic support or with app control haptics disabled still show the visual reveal. CoreHaptics failures fall back to visual-only playback.

## Tactile timing

Two stronger haptic-only transients with short continuous bodies use the shared `SonivoLaunchMotion` timeline at 1.00 and 1.84 seconds (strengths 1.00 and 0.80). The visual epoch and the haptic engine are both scheduled with a 35 ms lead. Stop/skip cancels queued events. No music haptics override, audio-session configuration change or fabricated beat detector input is introduced.

This is bounded launch choreography, not a promise of measured frame rate or sample-accurate synchronization on a physical device. SwiftUI chooses the display cadence; actual smoothness and Taptic feel require an iPhone test.

## Checks

The compiled Swift check executes the real timing/lifetime model: one-shot startup, inactive scenes, playback bypass, early skip, monotonic letter reveal, fade completion, finite input handling and time-based behavior at 30/60/120 sampling rates. Structural tests verify immediate root mounting, cancellation hooks, existing deep-link routing, no video/network startup dependency, accessibility and common haptic/visual timing. Final app compilation validates the SwiftUI/CoreHaptics integration on macOS.

## Reference

https://prompt-motion.com/jesscaroline7-1ff7cb — kinetic typography / app-motion reel used for direction only. Its video, artwork and code were not copied. Sonivo's native vectors and wordmark are original implementation.


## Motion polish v2
A longer assembly uses the shared strong ease-in-out curve; lettering then reveals with ease-out. The native vector mark gains a localized radial bloom and a bounded pulse tied to the haptic timeline. A narrow accent-colored sweep crosses the wordmark once, not a repeating shimmer. There is no fullscreen flash, large blur filter, particle simulation or added rendering dependency. Each haptic transient is followed after 20 ms by a 180 ms continuous body at 40% of the transient's intensity. Hardware feel is not asserted from those nominal values.

UI/UX Pro Max, Apple Design, Animate and Review Animations guidance was applied. Public references were inspected, not copied or installed:
- https://community.rive.app/c/showcase/building-an-engaging-splash-screen-with-rive
- https://mobbin.com/glossary/launch-screen
- https://reactbits.dev/text-animations/blur-text

| Before | After | Why |
| --- | --- | --- |
| 1.85 s compressed reveal | 3.25 s staged assembly/read/exit | Owner requested slower brand choreography; skip and playback bypass remain immediate. |
| Transients at 0.45/0.22 | Transients at 1.00/0.80 plus brief tactile bodies | Noticeable tactile punctuation rather than a longer continuous buzz. |
| Flat mark and text | Localized glow, subtle depth and one masked text sweep | Hierarchy and polish without heavy video/shader infrastructure. |

**Motion review — Approve code scope:** bounded cold-launch choreography, shared timing, cancellation/skip, native transforms/opacity, unchanged reduced-motion lifetime, no repeat on resume and no audio-session mutation. Longer timing is an explicit owner preference for this branded reveal, not a new duration for interactive UI. Physical smoothness and Taptic intensity still require the owner's iPhone check.

At accessibility text sizes, the nonessential tagline is omitted so the brand and the native Skip control do not compete for vertical space, especially in landscape.
