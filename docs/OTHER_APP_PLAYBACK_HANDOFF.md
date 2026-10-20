# Other-app playback / external-open handoff

## Findings and scope
Sonivo registers `sonivo` and the legacy `aurora` URL schemes, not `spotify`.
There is no associated-domain registration for Spotify and no code opening Spotify
URLs back into Sonivo. This audit does not establish why an ordinary Spotify home
screen icon would open a different app; that exact device interaction still needs
confirmation. System media-card/Island ownership is a separate, plausible conflict.

Confirmed risks in Sonivo before this change:
- Background paused/restored track metadata could be republished without a new
  playback request, including by delayed artwork work or elapsed-time updates.
- Foreground lifecycle could activate audio again based on stale playback state.
- Media remote-event registration happened during PlayerCore initialization.
- Every delivered URL/web-browsing activity opened the Sonivo full player without
  checking whether it was an app-owned playback route.
- Interruption resume did not check whether another app was still playing audio.

## Fix
`SonivoPlaybackOwnership` is a small value-state policy. Successful audio activation
establishes playback intent. Other audible audio or an interruption latches a yield;
late callbacks cannot regain ownership. A new successful playback activation can
establish intent again. Restoring a queue alone creates no ownership.

The policy gates legacy and experimental Now Playing publication and Live Activity
updates. Handoff clears only the surface this publisher actually owned, ends Sonivo's
Live Activity and stops remote-event receiving. Delayed artwork requires ownership
and a matching published track ID; it cannot fabricate a fresh metadata dictionary.
Experimental snapshot refresh rechecks ownership after awaiting its timeline.

Foreground changes do not reactivate the session. Remote-event receiving starts
only after successful playback activation, not merely opening the app. Interruption
resume still requires Apple's `shouldResume` and prior playback, and now also requires
that `isOtherAudioPlaying` is false. Pause/queue position/persistence are retained.

External URLs open the full player only for recognized `sonivo://player` and
`sonivo://track/<UUID>` routes (plus their legacy aurora equivalents). Foreign URLs,
unknown routes and arbitrary browsing activities are ignored. Media-item activity
must identify an owned route or current track and pass ownership checks. Accepted
routes only show the player; they do not automatically start audio.

## Sources
- https://developer.apple.com/documentation/avfaudio/avaudiosession/isotheraudioplaying
- https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionoptions/shouldresume
- https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:)

## Verification
Portable source guards plus a macOS executable fixture run the actual Swift policy:
restored/paused state, latched handoff, interrupted/resumed states, all eight resume
flag combinations, owned/foreign/malformed URL routes. Existing regression suites
retain pause/resume, startup, queue persistence, remote favorites and UI coverage.

CI cannot reproduce two third-party apps interacting on a physical iPhone. Verify:
1. Start Sonivo, switch to Spotify and start a track; media card/Island must remain
   Spotify's even after Sonivo's old artwork request completes.
2. Pause Sonivo first, start Spotify, then open Sonivo only to browse/settings;
   Spotify must keep playing. Only a deliberate Sonivo Play should take audio.
3. Open Spotify by normal app icon, by a Spotify link and by its system media card
   separately. An icon-only redirect would need additional device diagnosis.
4. Check calls/interruption resume, headset pause/resume, route removal and Sonivo's
   own player/track links. No claim of a completed physical-device reproduction.

EQ, icon assets, launch motion and music haptics are unchanged by this fix.
