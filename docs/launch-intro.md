# Sonivo True Focus launch intro

A 4.2-second native adaptation of the True Focus behavior requested by the owner: inactive words are blurred, the active word is clear, and four accent-colored corner markers travel between actual native text bounds. The sequence is Sonivo → Твоя → музыка → Sonivo. The wordmark starts near the available viewport width and contracts to its normal size; fitting includes the frame corners, viewport height and the Skip control clearance. There is no cropped giant text, forced font-layout resizing, web view or React runtime.

The implementation uses native SwiftUI text, bounded blur (0–5 pt), anchor preferences, a single eight-segment corner path and a transform-based zoom. Native geometry reporting measures the base word width and scene height; the fitting calculation is not based only on guessed font metrics. A nonisolated preference key returns a fresh default dictionary, avoiding shared actor-isolated static mutable state in layout callbacks.

## Shared physical timeline
Four focus-lock impulses at 0.70, 1.78, 2.56 and 3.36 seconds use strengths 1.00, 0.85, 0.90 and 1.00. Each is followed by a 240 ms continuous body at 55% of its strength. Six softer ticks accompany the large-to-normal contraction. Values stay inside the supported 0–1 intensity range: hardware intensity is not described as exceeding CoreHaptics' maximum. The visual epoch and the scheduled tactile pattern retain the shared 35 ms lead. The frame's localized glow responds to the same lock envelope. No audio events or audio-session configuration changes are introduced.

## Lifetime and accessibility
RootView still mounts immediately. Skip, scene deactivation after startup, disappearance, direct external playback opening or playback starting stops all pending tactile events and finishes the intro. The in-memory launch session does not replay on a return from the background. Disabled haptics/unsupported hardware yields visual-only behavior. Reduced Motion shows the settled, clear, standard-size brand for 0.35 seconds, with no moving frame, text blur, spatial zoom or tactile pattern. Accessibility text sizes omit the nonessential secondary words and keep the native Skip control.

The static iOS launch screen remains separate: this animation runs after it. No full-track downloads, streaming queue changes, beat detector modifications or renderer changes outside the intro are included.

## Verification
Structural checks guard root mounting, lifecycle, preferences, real geometry fitting, active/inactive-word blur, corner-frame rendering and shared tactile/zoom timing. The compiled Swift check executes the real model: weights remain normalized, blur stays within 0–5, focus-lock cues align to clear words, the zoom is monotonic and settles to 1, tactile values/times are valid, and cancellation/playback/reduced-motion lifetimes are preserved. Final macOS compilation verifies the actual SwiftUI/CoreHaptics code. Smoothness and motor feel require a physical iPhone; rendered preview videos are composition studies, not device recordings.

## Reference and motion review
- https://reactbits.dev/text-animations/true-focus
- https://github.com/DavidHDev/react-bits/blob/main/src/content/TextAnimations/TrueFocus/TrueFocus.jsx

The original demo and component behavior were inspected. This is a native adaptation of its focus/blur/corner-frame interaction, not a claim that the React component or an NPM package was installed into SwiftUI. No external assets or new runtime dependencies are used.

| Before | After | Why |
| --- | --- | --- |
| Small sound bars and staggered letters | Oversized wordmark, moving focus corners and inactive-word blur | Explicit owner's True Focus reference and near-full-width opening. |
| Two tactile cues | Four focus-lock impacts, short bodies and softer contraction ticks | A richer physical sequence without unsupported intensities or indefinite buzzing. |
| Fixed guessed opening size | Native word/scene measurements plus viewport fitting | Keep focus corners and the Skip control visible on small/landscape layouts. |

**Motion review — Approve code scope:** bounded launch-only choreography; Skip and playback bypass remain immediate. Normal-size landing, finite curve sampling, no indefinite loop, reduced-motion fallback, actor-safe preference defaults and unchanged root lifetime are covered. Device feel and frame rate remain unverified.
