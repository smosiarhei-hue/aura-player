# Track-radio diversity audit — not a playback change

The EQ/player layout update does not change station selection, recommendation ranking, listening feedback, queue replacement or refill behavior.

## Verified contract mismatch

The current `requestTrackStationQueue` sends comma-separated history in the legacy GET `rotor/station/{station}/tracks` `queue` parameter. The public Yandex client documents that parameter as a **single last-played track ID** to advance the radio chain, not a list of listening history. Its documentation also notes that legacy radio chains can repeat tracks. Thus the current comma-list is not a verified way to tell the service which songs have already been heard.

Other findings in our code:
- First track-radio request starts with only the seed, not the persisted recent-listening history.
- The helper supplies diversity/language/mood as GET parameters; the legacy settings client instead updates settings through POST `settings3`. Those query parameters alone are not verified settings updates.
- Fetching several batches stores only the last batch ID. Real listening feedback for an older batch can therefore be associated with the wrong batch.

These are code/contract findings, not measured evidence that a particular live-account recommendation was caused by one specific bug.

## Proposed separate change

Use the modern session contract: POST `/rotor/session/new` with track seed, documented `settingDiversity:discover`, a bounded queue of recent IDs and `trackToStartFrom`; retain its `radioSessionId`. Request continuations through POST `/rotor/session/{id}/tracks`. Associate each returned track with its batch. Send real started/finished/skipped feedback using the session event envelope and documented timestamp format, in playback order.

Do not treat prefetched tracks as heard. Preserve server order, the audible current track and the existing queue on error. Handle unknown/terminated sessions and cancellation without introducing a local AI/chart/random fallback. Keep the source exclusively Yandex. This requires its own mocked contract tests, macOS build and on-device account validation before claiming improved recommendations.

Spotify's public help describes song radio as a collection based on the chosen song/artist/album that updates to stay fresh; it does not disclose a ranking algorithm or promise that every recommendation is unheard. It is a product reference, not an API implementation to copy.

## Public references inspected

- https://support.spotify.com/us/article/spotify-radio/
- https://github.com/MarshalX/yandex-music-api/blob/main/yandex_music/_client/radio.py
- https://github.com/MarshalX/yandex-music-api/blob/main/yandex_music/_client/rotor_sessions.py
- https://yandex-music.readthedocs.io/en/main/yandex_music.client.html

No authenticated Yandex requests, full-track downloads or PCM persistence were performed for this audit.
