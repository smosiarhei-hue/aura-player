# Player quality and native dismissal

The player reads received stream codec/bitrate rather than labelling a requested preference as a delivered quality. The Yandex signed lossless endpoint may return a lossy answer; that answer is retained only as a fallback while legacy FLAC / higher-bitrate options are checked. A valid fallback remains playable if the legacy endpoint fails; account changes and cancellation never revive it.

Local/cached files use the encoded AVAudioFile format and AudioFile bitrate property instead of extension-based 320/256/1411 guesses. Direct streams without received metadata show unknown quality rather than fabricated 128 kbps. Crossfade completion transfers incoming quality facts with the incoming track, avoiding the previous track's badge. Bitrate alone never implies lossless or Hi-Res. No sample depth or sample rate is fabricated.

Explicit catalog quality selection retries even the already-selected preference, preserves the current playback position, and uses the existing single backend switching path. Saved catalog URLs do not bypass the requested quality when resolving a stream. A lossy offline file cannot be made lossless by a UI setting; the quality card explains a requested-lossless/current-lossy mismatch. Availability still depends on the service, account and track.

Historical zoom revision (superseded by the intent-safe controls revision below): all player entry points used fullScreenCover plus the native iOS zoom navigation transition, with matching transition sources. There are no sheet detents. iOS owns interactive zoom swipe dismissal; the prior competing manual offset/scale gesture is removed. The visual surface expands behind the status bar / Dynamic Island surroundings and home indicator, while controls use the original safe-area insets. Dismissal changes presentation only, not playback. Lyrics now sits between Favorite and More in the metadata row, and its former secondary-actions duplicate is removed. VoiceOver labels and disabled/no-track state are retained.

Local Python regression suite: 349 tests, four macOS-specific checks skipped on Linux. CI validates actual Swift value-model behavior and Xcode compilation. Real stream availability and physical swipe behavior must additionally be tested on an iPhone/account.


## Intent-safe controls revision

- Full-screen cover uses the native vertical presentation instead of whole-screen zoom/pinch dismissal. Interactive dismissal is disabled. The close button remains; only the header accepts a deliberate downward drag of at least 120 pt, with a strong vertical direction. Artwork, lyrics scrolling and audio controls are not close surfaces.
- Cover swipes require real horizontal travel (24% of width, bounded to 80–140 pt), not just predicted flick velocity. Outgoing artwork exits over 180 ms; incoming artwork settles over 420 ms. A generation-guarded lock and cancellation prevent duplicate track commands. Reduce Motion removes travel.
- Timeline and system volume accept horizontal drags only, with at least 10 pt travel and 1.6× horizontal direction dominance. Taps do nothing; adjustment is relative to the starting level, not the point touched, avoiding jumps. Playback seeks once on release; cancelled/vertical/stale-track drags do not seek. Volume remains the real system level; hardware keys and VoiceOver adjustment stay available.
- Background is a single muted current-cover tone, ranked by actual pixel area without saturation bonuses. Gray/black covers stay neutral; stale artwork cannot tint a different track. No multi-color gradient is added. Existing explicitly enabled VideoShot rendering is unchanged.
- Linux source/DSP tests and macOS Swift/native build checks do not replace an iPhone gesture, scrolling, Bluetooth or accessibility test.
