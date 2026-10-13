# SONIVO tactile launch

A finite three-second, native SwiftUI launch reveal. The regenerated bundled glass-ring graphic enters as one whole close-up from beyond the display edges and settles to the approved scale. The uppercase SONIVO wordmark is an intact text layer with an offline, OFL-renamed font subset.

## Visual / haptic clock

Both visual and Core Haptics events share one monotonic epoch. Scheduled cues:

| Seconds | Visual cue | Transient intensity / sharpness |
| --- | --- | --- |
| 1.12 | Ring fixation, recoil and outward light wave | 1.00 / 0.65 |
| 1.53 | Wordmark settle / light sweep | 0.95 / 0.75 |
| 2.30 | Home handoff begins | 0.80 / 0.50 |

A 980 ms shaped travel rumble starts at 80 ms during the close-up movement. The first two impacts have strong decaying bodies (260 ms and 140 ms); the full splash is not continuously vibrating. Intensity curves reset before each next impact. Actual perceived strength depends on hardware and must be checked on an iPhone.

The Metal layer shader integrates 24 positions over a 1/60-second exposure along the same scale trajectory as the Swift model. This is directional motion exposure, not permanent Gaussian blur. Sampling is disabled after settling. RootView mounts immediately; the 450 ms handoff finishes before the three-second deadline. No music/audio session changes or network calls are introduced.

The launch surface measures the full display, including the status-bar / Dynamic Island surroundings and home-indicator region. Only the Skip control retains the bottom safe-area inset. The system island and indicator remain system-owned; the app does not draw over the physical island.

## Accessibility and lifecycle

The existing haptics preference, unsupported hardware, Reduce Motion, skip, background, playback, deep links and view disappearance stop or bypass the pattern. Reduce Motion gets a brief static reveal without launch haptics. Reduce Transparency / increased contrast suppress decorative light effects. Core Haptics reset never replays the launch.

## Assets / verification

`scripts/materialize_app_icons.py` materializes the base64 PNG launch asset before Xcode compilation. Existing app-icon source assets are unchanged. No MP4 is embedded in the application.

UI UX Pro Max is pinned by `agent_skills/ui-ux-pro-max.lock.json`; `scripts/install_uiux_skill.py` verifies the archive and individual files before restoring the local skill. Skills are development guidance, not application runtime dependencies.

Local Python regression suite passes; Xcode/Metal compilation and on-device haptic/visual testing remain separate checks. The preview video is not an on-device recording.
