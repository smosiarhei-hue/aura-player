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

The original demo and component behavior were inspected. This is a native adaptation of its focus/blur/corner-frame interaction, not a claim that the React component or an NPM package was installed into SwiftUI. The brand now includes a small, offline SIL-OFL font derivative; no new runtime dependency is used.

| Before | After | Why |
| --- | --- | --- |
| Small sound bars and staggered letters | Oversized wordmark, moving focus corners and inactive-word blur | Explicit owner's True Focus reference and near-full-width opening. |
| Two tactile cues | Four focus-lock impacts, short bodies and softer contraction ticks | A richer physical sequence without unsupported intensities or indefinite buzzing. |
| Fixed guessed opening size | Native word/scene measurements plus viewport fitting | Keep focus corners and the Skip control visible on small/landscape layouts. |

**Motion review — Approve code scope:** bounded launch-only choreography; Skip and playback bypass remain immediate. Normal-size landing, finite curve sampling, no indefinite loop, reduced-motion fallback, actor-safe preference defaults and unchanged root lifetime are covered. Device feel and frame rate remain unverified.


## Cinematic typography revision (owner-authorized)

The True Focus sequence, 4.20-second duration, opening fit, 4 focus-lock cues, 6 contraction ticks and cancellation policy are unchanged. The wordmark now uses a static Unbounded ExtraBold derivative containing only the Sonivo glyphs, renamed `SonivoLaunchDisplay` under SIL OFL. The Russian secondary words remain native system typography; they are not rendered with a Latin-only subset. Font registration is done once, offline in the host task before the shared visual/tactile epoch. RootView is still already mounted. A system bold fallback remains available if registration fails. Provenance and source/derived hashes are in `launch-font-provenance.json`; the full license is in `ThirdPartyNotices/Unbounded-OFL.txt`.

A single stitchable Metal color effect gives **only the wordmark** curved silver reflections and a slow highlight sweep, clipped by the original antialiased glyph alpha. It preserves premultiplied alpha and clamps to SDR 0–1; this is not HDR/Dolby Vision output. On a light canvas it becomes dark polished metal, rather than unreadable white chrome. The existing inactive-word blur remains true defocus. There is no shutter-smear on the slow contraction: the motion guidance explicitly warns that this looks muddy, not cinematic.

The atmospheric backdrop uses two native radial light layers moved with small transforms from the same finite launch clock. No additional display link, ray marching, feedback rendering, live texture capture, WebView, NPM package or image/video playback is added to the iOS app. Reduced Motion disables moving material and light drift. Increased Contrast uses solid semantic text and hides the atmosphere; Reduce Transparency also hides the decorative light layers.

## Installed skills and native adaptation

Project-local selected skills are installed at `.agents/skills/`. The generated files are intentionally ignored by Git; their exact upstream commits, archive hashes and all 427 file hashes are committed in `agent_skills/motion-skills.lock.json`. Run `python3 scripts/install_motion_skills.py` to reproduce the installation on another machine. The installer validates content and never executes downloaded code. Full upstream notices are committed at `.agents/vendor-notices/`; a portable archive can accompany the handoff. These are local external-agent skills, not a global Notion skill installation or an installed HyperFrames renderer.

Applied guidance:
- HyperFrames creative typography/house style: one expressive face, material concept first, no flat empty backdrop or arbitrary font roulette. Unbounded was chosen after inspecting real glyphs rather than repeating the previous generic/syne samples.
- HyperFrames motion-blur reference: don't smear slow readable text; use the requested True Focus blur only on inactive words.
- Emil animate/review: reuse existing strong curves and timing, transform-only fit and drift, interruptible lifetime, no infinite animation.
- Paul Hudson SwiftUI Pro: actual deployment/toolchain from `project.yml`, stable view structure, bounded native shader, per-process asset preparation, accessibility and localized native controls. Do not assume newer SDK availability just because a vendor skill says so.

| Before | After | Why |
| --- | --- | --- |
| Rounded system black wordmark | Licensed Unbounded ExtraBold brand cut | Owner wants a more unusual, cinematic identity without italic. |
| Flat glyph color | One launch-only silver-reflection pass | Material visibly moves inside the letters without unreadable deformation. |
| Static central glow | Two restrained native light layers sharing the launch clock | Depth and ambient movement, not a rotating or full-screen storm. |
| Slow contraction with possible suggested smear | Keep contraction crisp; preserve inactive-word defocus | Follow motion guidance: blur should describe focus, not manufacture softness. |

**Review — Approve code scope, pending native build/device QA:** no extra blocking wait, no audio changes, no SDK bump, no extra tactile events, preserved Skip/theme/accessibility. Structural asset/material checks and real macOS font/glyph checks supplement the existing timing/lifetime tests. Preview videos remain composition studies; physical iPhone performance and tactile feel are not established by them.
