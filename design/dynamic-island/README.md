# Sonivo capture branding and Live Activity

The approved `preview.svg` and exact PNG payload `preview.png.b64` are committed together with the implementation. The EQ preview is included as `eq-preview.svg` and a lossless pixel-equivalent `eq-preview.webp.b64`. They are design mocks, not iOS screenshots. Decode PNG with `python3 -c "import base64,pathlib; p=pathlib.Path('design/dynamic-island/preview.png.b64'); p.with_suffix('').write_bytes(base64.b64decode(p.read_text()))"`.

## Working in-app branding

A real SwiftUI safe-area brand row shows the original selected mark and Sonivo in the selected application accent. It is enabled by default for screenshots; turn off **Оформление → Sonivo на экране → Бренд на экране** to hide it normally. During screen capture, the row appears regardless of that preference. It does not create a fake system Dynamic Island, cover the camera, intercept recordings, save images or upload screen content. iOS `EnvironmentValues.isSceneCaptured` drives capture state. A screenshot is reported after capture, so no post-capture brand overlay is attempted.

Home/tab pages, root settings/auth sheets, the full player and its EQ/queue/settings/quality sheets use the row. Native system UI and unrelated external apps remain untouched. Reduced Motion needs no special timer because the waveform is a static brand/status glyph, not a fake PCM visualizer. The EQ button now uses precise rounded faders with the same accent, glass surface and 44-point accessible touch target. EQ gains/presets/audio routing are unchanged.

## Real Dynamic Island / Lock Screen

`SonivoLiveActivity` is a WidgetKit extension. It provides compact, expanded and minimal states, selected brand geometry, accent and system-timer playback progress. Tapping opens `sonivo://player`. Playback controls are intentionally not fabricated in the extension: it displays playback status and opens the real player. ActivityKit presents content when/where iOS allows; it cannot replace the screen-recording or privacy indicators, force foreground placement, or pre-empt other activities.

State contains a local playback UUID, generic source label, mark, accent, play state and timing only; no OAuth credentials, account identifiers, stream URL, track titles or artist data. The UI actor passes only Sendable state and IDs to a concurrent SDK runtime; non-Sendable Activity handles never cross its boundary. A single UI worker serializes/coalesces updates, reconciles restored activities, ends on stopped playback/disabled setting, and requests new activities only while foregrounded. No push tokens, server, audio capture, custom audio clock or per-frame updates are introduced.

### Signing / install safety

Existing CI configures only the application profile. A separately signed extension requires GitHub Actions secret **SONIVO_ACTIVITY_PROFILE_BASE64**: base64 of a valid Apple mobileprovision for `<actual app bundle identifier>.LiveActivity`, same signing team/certificate/distribution and app-device coverage. Do not share it in chat. Add it using GitHub's Secrets interface.

CI validates that profile, assigns profiles per target, signs the embedded extension before the parent and verifies signatures. Without the extension secret, signed IPA builds **exclude** the extension and set `SonivoLiveActivityEmbedded`/`NSSupportsLiveActivities` false; the Dynamic Island setting explains this and is disabled. The in-app brand row still works. CI separately compiles the extension unsigned for iOS Simulator. Passing compilation does not mean that a profileless signed IPA contains a functioning Live Activity.

Direct Xcode developer builds keep the extension target embedded by default and require appropriate automatic/manual signing configuration for both targets. No provisioning profile or certificate is committed.

## Apple references
- https://developer.apple.com/documentation/swiftui/environmentvalues/isscenecaptured
- https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:)
- https://developer.apple.com/documentation/widgetkit/dynamicisland

Actual iPhone display, prioritization alongside screen recording, screenshots and lock-screen behavior still require device validation. Never claim system recording indicator replacement.
