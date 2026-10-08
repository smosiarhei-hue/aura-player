# Full player: track wave and secondary actions

## Scope
- Branch: `feature/modern-my-wave-home`.
- Full-player standard mode uses one native vertical ScrollView. Lyrics/karaoke layout is unchanged.
- Metadata, seek, playback and the system volume slider remain above the wide animated **Моя волна** button. Lyrics, AirPlay, sleep timer, EQ and queue remain accessible below it.
- Dismiss drag is restricted to the header so scrolling/sliders do not dismiss the player. The explicit close button and artwork horizontal track swipe remain.
- The button uses semantic text/surface colors, artwork hues and a small three-path Canvas (at most 30 updates/s). It is decoration, **not** a replacement beat detector. Hidden, paused, backgrounded and Reduced Motion states pause it. It creates no Metal renderer, audio player, tap, PCM queue or new dependencies.

## Yandex-only track radio
- A real `ym_<catalogID>.mp3` identifier seeds `track:<catalogID>`.
- The returned rotor sequence/order is retained. Only unavailable tracks, the seed/already queued IDs and exact duplicates are excluded. Existing explicit dislikes remain excluded during automatic refill.
- No local audio-vector inference, duration/artist ranking, random shuffling, Gemini reranking, artist/genre stations, personal picks or chart fallback are used for this path.
- API requests use the app's existing authenticated Yandex Music transport and server-side wave filters. This is the existing third-party Yandex API integration, not a claim of an official public SDK or exact parity with every official client feature.
- A successful button request replaces upcoming tracks without restarting the current song. Failure leaves the previous queue/station intact and exposes a retryable message.
- Request, rotor-session and playback identities plus cooperative cancellation reject obsolete responses. Initial batch and all three automatic refill paths use the same track station.
- Local/imported files without a Yandex ID cannot start this station. No title-based guess or catalog search fallback is made.
- The separately labelled AI-vibe feature and artist-wave feature are outside this change; the new button never calls them.

## Validation
- Eight new Linux source-regression checks cover API-only sources, order/HTTP checks, generation guards, all refill paths, visual/control hierarchy, loading/accessibility, animation lifecycle and leaving the local vibe engine.
- macOS CI compiles the actual three Swift request/start/refill methods under Swift 6/MainActor with a stub transport. Executable fixtures cover sequence order, duplicates, queue context, error/empty response, playback/station changes, competing starts, refill and cancellation. No credentials or live music are used.
- Existing DSP/EQ/capture/visualizer timing/haptics pins are unchanged.
- Layout mock renders are **not** native iPhone execution. On-device validation still required: small phone and landscape, accessibility text, Reduce Motion, VoiceOver, header-dismiss vs content scroll, AirPlay/EQ/lyrics/queue sheets, delayed/failed API response, and continued automatic recommendations after several tracks.

## Pre-push result
Linux: `python3 -m unittest discover -s .github/scripts -p 'test_*.py'` — 220 tests, 219 passed and the existing macOS-only compiled Swift test skipped. No test pins were weakened. macOS result belongs to the commit's Build IPA run, not this Linux result.

## Native glass and neutral naming refinement
- Button title is **Моя волна по текущему треку**. No service/provider name is shown or spoken in its label/hint. Minimum height (84pt), width and position are unchanged.
- The surface is real SwiftUI `glassEffect(.regular.tint(...).interactive(), in: .rect(...))`, not a drawn border or custom blur imitation. The lightweight animated color is transparent and behind the native glass; there is no opaque painted card beneath it.
- Tint comes only from the current track's extracted cover palette, with a subtle 12% native glass tint. Until that cover is resolved, it is neutral; neither mood guesses nor a randomly seeded color substitute is used. Palette extraction rejects cancelled/previous-track results.
- Recommendation/API/refill logic is unchanged by this appearance refinement.
- Appearance refinement Linux checks: 222 tests, 221 passed, one existing macOS-only skip. Native glass appearance still requires an iPhone; HTML mocks only check text/layout.
