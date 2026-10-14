# Sonivo capture branding and Live Activity

The approved `preview.svg` and exact PNG payload `preview.png.b64` are committed together with the implementation. The EQ preview is included as `eq-preview.svg` and a lossless pixel-equivalent `eq-preview.webp.b64`. They are design mocks, not iOS screenshots. Decode PNG with `python3 -c "import base64,pathlib; p=pathlib.Path('design/dynamic-island/preview.png.b64'); p.with_suffix('').write_bytes(base64.b64decode(p.read_text()))"`.

## Corrected scope: system island only

The separate in-app brand row was rejected and removed. Home, settings and player safe-area/layout behavior is restored. No bar appears during recording or screenshots. Only a nonvisual lifecycle modifier remains to synchronize theme, selected mark, settings and foreground state with ActivityKit. There is no screenshot listener, fake island, camera overlay or capture-specific layout change.

The approved preview images remain versioned for provenance; their in-app row is an obsolete concept and is NOT the current interface. iOS reports screenshots after capture. An app cannot invisibly reserve the system island and then insert its logo specifically into the screenshot. A real Live Activity can be captured only while iOS already displays it. Screen-recording/privacy indicators cannot be replaced.

The custom player EQ icon remains, with its accent, 44-point tap target and unchanged action. EQ gains, presets and audio routing are untouched.

## Real Dynamic Island / Lock Screen

`SonivoLiveActivity` is a WidgetKit extension. It provides compact, expanded and minimal states, selected brand geometry, accent and system-timer playback progress. Tapping opens `sonivo://player`. Playback controls are intentionally not fabricated in the extension: it displays playback status and opens the real player. ActivityKit presents content when/where iOS allows; it cannot replace the screen-recording or privacy indicators, force foreground placement, or pre-empt other activities.

State contains a local playback UUID, generic source label, mark, accent, play state and timing only; no OAuth credentials, account identifiers, stream URL, track titles or artist data. The UI actor passes only Sendable state and IDs to a concurrent SDK runtime; non-Sendable Activity handles never cross its boundary. A single UI worker serializes/coalesces updates, reconciles restored activities, ends on stopped playback/disabled setting, and requests new activities only while foregrounded. No push tokens, server, audio capture, custom audio clock or per-frame updates are introduced.

### Signing / install safety

Existing CI configures only the application profile. A separately signed extension requires GitHub Actions secret **SONIVO_ACTIVITY_PROFILE_BASE64**: base64 of a valid Apple mobileprovision for `<actual app bundle identifier>.LiveActivity`, same signing team/certificate/distribution and app-device coverage. Do not share it in chat. Add it using GitHub's Secrets interface.

CI validates that profile, assigns profiles per target, signs the embedded extension before the parent and verifies signatures. Without the extension secret, signed IPA builds **exclude** the extension and set `SonivoLiveActivityEmbedded`/`NSSupportsLiveActivities` false; the Dynamic Island setting explains this and is disabled. There is no in-app fallback bar. CI separately compiles the extension unsigned for iOS Simulator. Passing compilation does not mean that a profileless signed IPA contains a functioning Live Activity.

Direct Xcode developer builds keep the extension target embedded by default and require appropriate automatic/manual signing configuration for both targets. No provisioning profile or certificate is committed.

## Apple references
- https://developer.apple.com/documentation/swiftui/environmentvalues/isscenecaptured
- https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:)
- https://developer.apple.com/documentation/widgetkit/dynamicisland

Actual iPhone display, prioritization alongside screen recording, screenshots and lock-screen behavior still require device validation. Never claim system recording indicator replacement.
