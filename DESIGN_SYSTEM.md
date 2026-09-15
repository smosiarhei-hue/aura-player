# Aura Player — Design System and UI Plan

## 1. Product direction

Aura Player is a cinematic iOS music player: artwork and sound create the atmosphere, while playback controls remain predictable and calm. The visual language is **Aurora Cinematic / Liquid Glass 2.0** — dark OLED surfaces, restrained glass, artwork-driven color, native iOS typography and meaningful motion.

The design must never hide the real playback state. The current track, active engine, AutoMix state, EQ state and loading state are always recoverable from the UI.

## 2. Platform rules

- Native SwiftUI first; no web/npm runtime in the iOS app.
- SF Pro and Dynamic Type; no fixed text sizes in feature screens.
- Minimum 44pt hit area for every control.
- Respect safe areas, Dynamic Island, landscape and Reduce Motion.
- Use semantic tokens from `Aurora/theme.swift`; views must not invent raw colors or random corner radii.
- Use SF Symbols with one consistent weight family; no emoji as structural icons.
- Use native sheets, navigation, menus, materials and haptics where they improve clarity.

## 3. Visual tokens

### Color

- Canvas: OLED black, raised black and charcoal surfaces.
- Primary accent: amber/ember for the main playback action.
- Artwork accents: sampled from the current cover and used only for atmosphere and secondary tinting.
- Semantic colors: heart, positive, warning and error must remain readable independently of artwork.
- Every artwork-driven background receives a dark readability scrim before text and controls are rendered.

### Shape and spacing

- 4pt base grid; common spacing 8/12/16/24/32.
- Small controls: 12pt radius or capsule.
- Cards: 20pt radius.
- Hero artwork and sheets: 28pt radius.
- One elevation language: material, hairline border and restrained glow instead of heavy shadows.

### Motion

- Fast interaction: approximately 220ms spring.
- Default layout/content change: approximately 360ms spring.
- Large artwork/sheet transition: approximately 550ms spring.
- Press feedback scales to about 0.965 and never changes layout bounds.
- Content entrance is a short fade + 18pt rise with a 30–50ms stagger.
- Exit is shorter than entrance; all animations are interruptible.
- Reduce Motion disables mesh motion, video ambience, parallax and decorative looping while preserving state feedback.

## 4. App structure

### Home / My Wave

- Top bar: profile/settings, centered product title, search.
- Hero: current mood/wave with one primary play action.
- Current track card: artwork, title, artist, live equalizer and compact controls.
- Sections: mood stations, recent listening, recommendations, charts and albums.
- Loading: skeleton cards or a calm progress state, never a blank screen.
- Empty state: explain what is missing and provide one action to recover.

### Library

- Segmented or tabbed filtering for tracks, albums, artists, favorites and downloads.
- Artwork cards use consistent aspect ratio and reserved space to prevent jumps.
- Long lists use lazy loading and stable row identity.
- Swipe actions are supplementary; every important action also has a visible menu.

### Search and discovery

- Search field opens with focus and a clear cancel route.
- Results show source type, artwork, title and artist without ambiguous duplicate rows.
- Loading, offline, no-results and authorization states each have a recovery action.
- Opening a result uses a shared artwork transition into the player or detail screen.

### Mini player

- Pinned above the tab/navigation area with safe-area-aware bottom padding.
- Shows the actual router-owned track, not a stale view-model value.
- Tap opens the full player; play/pause and next remain available as 44pt controls.
- Loading state disables duplicate transport taps and shows a compact progress indicator.

### Full player

- Header: dismiss, connection/output route, overflow menu.
- Hero: artwork or video shot with one controlled ambient background layer.
- Metadata: title and artist with stable layout during track changes.
- Scrubber: elapsed/remaining time, accessible labels and optional haptic ticks.
- Controls: previous, play/pause, next; secondary controls for favorite, queue, lyrics and EQ.
- AutoMix is shown as a clear stateful control, never as a hidden dependency of EQ.
- Horizontal artwork swipe maps to previous/next and has visible button alternatives.
- Opening from the mini player uses a matched/shared artwork transition.
- Dismissal uses the standard downward sheet gesture; it never stops playback.

### Queue

- Current item is visually and semantically marked.
- Drag reorder has a visible alternative through menus.
- Duplicate tracks remain distinguishable by stable identity and source metadata.
- Queue updates animate as row moves, not as a full list reset.

### Equalizer

- EQ is an independent audio feature with its own explicit On/Off state.
- Presets appear first; manual 10-band controls are progressively disclosed.
- Changes show immediate feedback and persist independently from AutoMix.
- If an engine cannot apply a band in the current mode, the UI explains why and offers a recovery path.
- Spectrum/visualizer animation is decorative and must not control whether EQ is active.

### AutoMix / NeuroMix

- One status surface shows engine, transition state, next track and confidence/diagnostic detail when requested.
- Start/stop/toggle commands are idempotent and show loading feedback.
- Cold launch restores the intended state without starting a second player.
- Transition overlay is short, readable and never covers the primary transport controls.

### Lyrics

- Lyrics open as a native sheet with clear close action.
- Current line is emphasized; scrolling remains user-controlled.
- Font size follows Dynamic Type and the user’s lyrics size setting.
- Missing, loading and offset-adjustment states are explicit.

### Settings and diagnostics

- Grouped native settings: playback, AutoMix, EQ, haptics, lyrics, appearance, account and diagnostics.
- Destructive actions are separated and confirmed.
- Diagnostics are available but never dominate the player UI.
- Every toggle has a visible label and a meaningful accessibility value.

## 5. Artwork, backgrounds and animation

- Prefer cached artwork as the source of the palette.
- Render a blurred artwork layer, a low-opacity procedural Aurora layer and a dark scrim; never stack multiple competing video players.
- Use `FluidAura.metal`/`FluidWaveView` only for the ambient layer; playback and visual animation remain separate concerns.
- Video shots are optional content, paused when the scene is inactive and disabled under Reduce Motion.
- Cover changes crossfade/scale with the metadata rather than rebuilding the whole screen.
- Keep one or two moving focal elements per screen; decorative motion must not compete with the current track.

## 6. Interaction states to implement everywhere

Every interactive component has: normal, pressed, focused, disabled, loading, success, error and offline/unauthorized variants where applicable.

Every async playback action must:

1. accept the first tap immediately;
2. expose a loading state;
3. ignore or cancel stale duplicate commands;
4. update the real active track and Now Playing metadata;
5. expose a retry path on failure.

## 7. Accessibility and device review

- VoiceOver labels describe the action and current state, for example “Пауза, играет…” or “AutoMix включён”.
- Color is never the only indication of state.
- Test small iPhone, iPhone 17 Pro-sized layout, large iPhone, iPad and landscape.
- Test Dynamic Type at the largest practical size.
- Test Reduce Motion, VoiceOver, offline mode, cold launch, Bluetooth/headphones connect/disconnect and interruptions.
- Verify that no control is hidden behind the Dynamic Island or home indicator.

## 8. Implementation order

1. Consolidate shared tokens and reusable surfaces in `theme.swift`/`glassfx.swift`.
2. Finish playback-state presentation: mini player, full player, loading and error states.
3. Rebuild Home, Library, Search and Queue around stable cards and shared artwork components.
4. Rebuild full player, lyrics, EQ and AutoMix sheets with the same tokens and motion.
5. Add artwork palette extraction, Aurora background and shared-element transitions with Reduce Motion fallback.
6. Add accessibility labels, Dynamic Type, haptics gating and empty/loading/offline states.
7. Run CI IPA build and verify on a real iPhone with cold launch, headphones and repeated transport commands.

## 9. Definition of done

- There is one visible source of truth for the active track and playback owner.
- EQ works independently of AutoMix.
- No duplicate player or stale Now Playing metadata appears after relaunch or repeated taps.
- Every major screen has loading, empty, error and accessibility states.
- Visual language is consistent across Home, Library, Search, Queue, Player, EQ, AutoMix and Settings.
- Motion is smooth in normal mode and calm/functional with Reduce Motion enabled.
- IPA builds in GitHub Actions and is tested on the target iPhone.

## 10. Complete project screen inventory

This section is based on the current SwiftUI surface area, so no existing product area is lost during the redesign.

### App shell and navigation

- `RootView`: four primary destinations — My Wave, Trends, Collection and Search.
- Persistent native mini player above the tab bar with artwork, progress, play/pause and next.
- Full-screen player presentation with zoom/shared artwork transition.
- Deep links, media-item continuation and external playback events must land on the real active player.
- Tab bar, bottom accessory, sheets and full-screen covers need one consistent material and safe-area treatment.

### Main screen: My Wave

- Profile/avatar entry to settings.
- Search entry.
- Mood/wave hero with animated fluid background and primary play action.
- Current playing track card.
- Mood station cards.
- Chart/top tracks section.
- Album/release cards.
- Loading, signed-out, unavailable-network and empty recommendations states.

### Trends / Explore

- “What to listen to” discovery cards.
- Favorites shortcut card.
- Listening history shortcut card.
- Artist-recommended release section.
- New releases carousel.
- Discovery controls: top charts and language filters.
- Top 100 chart entry and full chart list.
- Popular artists carousel with rank labels.
- New track/premiere section.
- Each carousel needs stable artwork sizing, loading placeholders and a full-list route.

### Collection / Library

- Favorites list with play-all and per-track actions.
- Listening history list with clear-history action.
- Category catalog and collection/series results.
- Local audio import through Files: supported formats, progress, success and error states.
- Local tracks with play, favorite, delete and context menu actions.
- AutoMix local-file test area and diagnostics/log export actions.
- User playlists: create, empty state, track count, open and delete confirmation.
- Recently added tracks.
- Media library scan, index reset and recovery states.

### Search

- Search field, cancel and clear actions.
- Track, artist, album and category result types.
- Result rows with artwork, title, subtitle, source and context actions.
- Artist and album navigation from result rows.
- Loading, no results, offline and authorization states.

### Artist cards and artist detail

- Artist card: circular artwork, name, chart rank/metadata and navigation affordance.
- Artist hero: cover image, artist name, subtitle and primary Listen action.
- Secondary Wave action for artist radio.
- Artist stats card with clear labels and consistent number styling.
- Popular tracks list with row actions and active-track indicator.
- Latest albums and complete albums sections.
- Album cards show artwork, release year, genre and track count.
- Similar artists carousel uses circular artwork and an accessible navigation label.
- Failure state includes message and Retry action.

### Album detail

- Album hero with artwork, title, artist link, year and metadata.
- Primary play action.
- Artist navigation with explicit affordance.
- Track list with active row, duration, favorite and context actions.
- Empty/failed album state and retry.

### Player secondary surfaces

- Queue sheet with current item, reorder, remove and clear actions.
- Lyrics sheet with synced, static, loading and empty states.
- Equalizer sheet with presets, enabled state and manual graph/bands.
- Sleep timer sheet with duration, active countdown and cancel.
- Quality sheet with selected state and explanatory detail.
- AutoMix transition overlay and diagnostics.
- Artist selection sheet when a track has multiple artist matches.
- Overflow menu with lyrics, queue, EQ, sleep timer, settings, diagnostics and stop/clear.

### Settings and account

- Yandex account: sign-in, avatar/profile, Plus state, sync, logout and auth failure.
- Apple/social account: signed-in profile, favorites binding and logout.
- Playback engine: ordinary playback, AutoMix V2, NeuroMix, current engine and diagnostics.
- Sound: independent EQ status and entry point.
- Audio quality and ordinary transition/crossfade configuration.
- Haptics: playback and scrub toggles.
- Karaoke: font size and synchronization offset.
- Media library: track count, rescan and destructive index reset.
- About: name, version, build and design system label.

### Authentication, audio and diagnostics

- Yandex OAuth sheet and web authentication states.
- Sign in with Apple state and failure recovery.
- AirPlay route control and output route changes.
- Headphone/Bluetooth connect and disconnect feedback.
- Audio interruption, background, foreground and inactive-scene states.
- AutoMix diagnostics, logs, export/send status and retry.
- All technical failures must be expressed in user language first, with detailed diagnostics available second.

## 11. Component map for the redesign

- `AuraScreenBackground`: artwork palette, Aurora layer, scrim and Reduce Motion fallback.
- `AuraArtworkCard`: remote/local artwork, placeholder, loading, failed image and shared transition source.
- `AuraTrackRow`: artwork, metadata, duration, active/loading indicator, favorite and context actions.
- `AuraSectionHeader`: title, optional subtitle and “See all” action.
- `AuraGlassButton`: primary, secondary, destructive and loading variants.
- `AuraStatusBadge`: AutoMix, EQ, download, offline and active playback states.
- `AuraEmptyState`: illustration/gradient, explanation and one recovery action.
- `AuraLoadingState`: skeleton for cards/rows and non-blocking progress for actions.
- `AuraErrorState`: concise cause, retry action and optional diagnostics link.
- `AuraArtistCard`, `AuraAlbumCard`, `AuraMoodCard`, `AuraChartRow`.

Existing files should be migrated toward this map instead of creating another parallel visual language.
