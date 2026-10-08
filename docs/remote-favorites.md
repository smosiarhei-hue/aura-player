# Native remote favorites

PlayerCore registers one `MPRemoteCommandCenter.likeCommand` target for each configured system command center. The transport router leaves feedback targets intact. The command is enabled only for a current track, publishes `isActive` from LibraryStore, and uses the app's Russian/English favorite labels.

A thread-safe snapshot captures the advertised track before dispatch to MainActor. Its UUID is revalidated before mutation, so an event queued while skipping cannot favorite the next track. `MPFeedbackCommandEvent.isNegative` maps to an absolute desired favorite state (negative removes favorite, not dislike). LibraryStore applies idempotently through its existing toggle/like/unlike path. Existing persistence and Yandex API calls are reused; no audio file download is added.

Library track changes notify the player so in-app/cloud/removal changes refresh system feedback state. Track publication also refreshes it. Existing play/pause/skip/seek handling and playback engines are unchanged.

Apple sources:
- https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter/likecommand
- https://developer.apple.com/documentation/mediaplayer/mpfeedbackcommand/isactive
- https://developer.apple.com/documentation/mediaplayer/mpfeedbackcommandevent/isnegative

## UI limitation and device validation
This enables the native feedback action; it cannot force iOS to display a heart in every Lock Screen, Control Center, accessory or car UI layout. This change does not create a custom Lock Screen widget or Live Activity. Check which system surfaces expose the command on the owner's iPhone/iOS version.

Verify streamed Yandex and local tracks, add/remove twice, switch tracks, pause, rapid next + favorite, change favorite inside the app and cloud library refresh. Confirm the local library and system active state agree, and Yandex server synchronization succeeds when authenticated/online. Server failures retain the app's existing handling; CI does not prove remote server delivery or system button visibility.
