# Local-first launch, native account UI, automatic VideoShots

## Local mode

The existing Sonivo launch animation/blur handoff is unchanged. After it, a user
without a verified persisted personal account sees a local home rather than an
empty online catalog. Sign-in is optional, never a forced first-launch modal.
Guest tabs: Home, Library, local Search. New Releases/Radio and catalog search
are mounted only for signed-in users. Existing account holders retain the
ordinary home/My Wave and all online tabs; no forced re-login or token migration.

Local home imports real audio through the existing LocalAudioDocumentPicker and
LibraryStore import pipeline, with import progress, cancellation, errors and
success feedback. Existing imported tracks can be played directly. No sample
songs, remote recommendations or HTTP requests are added to the guest views.
Local search searches title/artist/album only. Library lists, playlist resolution,
play queues and the primary PlayerCore.play entry point exclude streaming audio
while logged out. Files/local favorites are not deleted. After logout any active
stream and queued streams are cleared; local playback is retained.

The account sheet is anchored on RootView (not on a guest-only child) so replacing
the home after a verified login cannot destroy the in-flight sheet. Settings'
existing account flow is retained.

## Account UI and motion

Approved Focus → Glass direction: native Liquid Glass cards, existing licensed
Unbounded Sonivo wordmark and bounded SDR chrome shader. System Dynamic Type for
all instructional text; semantic colors in light/dark mode. Reuses installed
Apple Design/Animate/SwiftUI Pro guidance and existing motion tokens. No package,
SDK-target, font-license or dependency changes.

- Real introduction → code/pending → verification → success states.
- Short native opacity/8pt transitions; no moving/blurring/zooming the code.
- One-shot 4.2s wordmark sheen, not a perpetual full-screen rendering loop.
- Code countdown at 1Hz uses the existing monotonic deadline; it doesn't drive
  OAuth polling. The code remains selectable/copyable. Raw credentials never
  appear in diagnostic messages.
- Success only after loginWithOAuthToken verifies/install its Keychain session;
  an optional 250ms success state + existing preference-gated success haptic,
  followed by native sheet dismissal. Reduce Motion removes offset/sheen/delay
  and success haptic; system controls, scrolling and close remain available.
- Manual-token alternate method, unofficial-client disclosure and cancellation
  remain. The working Device Flow protocol/client/token refresh/URL allowlist
  are NOT changed in this feature.

## VideoShots

The owner explicitly authorized changing the old opt-in source-test expectation
and requested default automatic playback with a Settings off switch.

`@AppStorage("sonivo_videoshot_enabled")` is shared by full player, its menu and
Settings → Player appearance → VideoShots, default **true** for absent values.
A stored explicit false remains false. Generating a video cannot silently reset
that preference. There is no automatic AI generation, full-song download,
automatic video-to-Documents saving or implicit hardcoded LAN probing.

Two confirmed defects were addressed: default false prevented discovery while
its enable button required an already discovered URL; and the full-player body
never actually attached VideoShotPlayerView even with a prepared video player.
Now video is a separate optional background layer; the protected spatially
uniform cover-color background remains the normal/failure fallback.

Video load is a cancellable SwiftUI task keyed by displayed/current track IDs,
preference, Reduce Motion and account generation. Readiness follows the active
AVPlayerItem (including looper replacement items), not merely construction of an
AVQueuePlayer. Old readiness callbacks/results cannot attach to a newer track.
Failure falls back to the cover. A silent AVQueuePlayer/AVPlayerLooper uses no
new audio-session configuration. Play only when music plays, player is visible,
scene is active, identity matches, asset is ready and lyrics/Reduce Motion are off.
Pause with music, backgrounding or hidden lyrics; tear down when disabled or
leaving the player. Without sign-in, only an existing local/bundled video is used;
no remote VideoShot lookup. Account logout/replacement clears VideoShot URL cache.
Not every track has an official VideoShot; missing video does not trigger AI.

## Checks and device validation

Eight source regression tests in `test_local_first_and_video_autoplay.py`; the
existing opt-in test was updated ONLY for the explicitly approved default-on
behavior, keeping no-auto-save/no-detached-task checks. Existing macOS compiled
Swift validation also runs VideoShot policy over all 256 Boolean combinations
and verifies changes of track/current playback/account/preference/reduced motion
invalidate the keyed load. All previous OAuth tests and protected audio/beat
pins remain; no EQ/DSP/beat detector/radio ranking changes.

Physical-device QA still required: import Files audio, cancel/import failure,
local search/favorites/playlist playback; existing logged-in launch, optional
login/code/cancel/success and logout; VideoShot-enabled track, consecutive track
changes, missing/expired video URL, pause/resume/background, lyrics, Reduce Motion,
Settings toggle live and across restart. No iPhone video decode/performance or
physical haptic claim is inferred from CI or the design-preview MP4.

## VideoShot layout stability

The standard artwork stage reserves the same `min(width - 40, height * 0.44)`
height whether video is pending, ready, failed, or disabled. The full-screen
video remains a clipped, non-interactive background layer. Revealing it must
not move metadata, timeline, transport, volume, or the track-wave button, and
must not reset the existing ScrollView offset. The artwork's empty video state
retains the same frame and swipe surface. AVPlayerLayer updates rebind only
when player identity or video gravity actually changes.

Device regression checks: slow VideoShot readiness, switch off/on, missing or
failed video, next/previous track, scrolled actions, portrait/landscape, light/dark
and larger Dynamic Type. Compare control positions before and after readiness
without dragging or rotating the phone. This fix does not redesign controls
or alter music playback, recommendation, or audio DSP behavior.
