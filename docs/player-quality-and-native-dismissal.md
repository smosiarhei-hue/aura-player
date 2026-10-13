# Player quality and native dismissal

The player reads received stream codec/bitrate rather than labelling a requested preference as a delivered quality. The Yandex signed lossless endpoint may return a lossy answer; that answer is retained only as a fallback while legacy FLAC / higher-bitrate options are checked. A valid fallback remains playable if the legacy endpoint fails; account changes and cancellation never revive it.

Local/cached files use the encoded AVAudioFile format and AudioFile bitrate property instead of extension-based 320/256/1411 guesses. Direct streams without received metadata show unknown quality rather than fabricated 128 kbps. Crossfade completion transfers incoming quality facts with the incoming track, avoiding the previous track's badge. Bitrate alone never implies lossless or Hi-Res. No sample depth or sample rate is fabricated.

Explicit catalog quality selection retries even the already-selected preference, preserves the current playback position, and uses the existing single backend switching path. Saved catalog URLs do not bypass the requested quality when resolving a stream. A lossy offline file cannot be made lossless by a UI setting; the quality card explains a requested-lossless/current-lossy mismatch. Availability still depends on the service, account and track.

All player entry points use the same native large sheet. iOS owns drag dismissal, inertia and scroll arbitration; the prior competing manual offset/scale gesture is removed. Dismissal changes presentation only, not playback. Lyrics now sits between Favorite and More in the metadata row, and its former secondary-actions duplicate is removed. VoiceOver labels and disabled/no-track state are retained.

Local Python regression suite: 349 tests, four macOS-specific checks skipped on Linux. CI validates actual Swift value-model behavior and Xcode compilation. Real stream availability and physical swipe behavior must additionally be tested on an iPhone/account.
