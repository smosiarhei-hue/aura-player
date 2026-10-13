# My Wave: server-session continuation

Protocol reference: MarshalX/yandex-music-api commit
`9ca132e5c18a72aab779c1fc68c169380a9357d0`, `_client/rotor_sessions.py`,
`_client/wave.py`, `rotor/session_event.py`. This is an unofficial client API;
server recommendation/ranking internals are not public.

- GET `/rotor/wave/settings?seeds=...`: requested values must exist in
  `settingRestrictions.*.possibleValues`; use the returned `serializedSeed`.
  Unsupported values are an explicit error, not guessed query parameters.
- POST `/rotor/session/new`: seeds, array queue, optional trackToStartFrom.
  Retain radioSessionId, batchId and the server's sequence. Do not clip away
  a returned batch tail to meet a local target count.
- POST `/rotor/session/{id}/tracks`: continue that same session with an array
  of already issued/queued IDs. Single-flight continuation, bounded issued
  history (1000 IDs), local queue exclusion and within-batch dedup. Preserve an
  unacknowledged batch until it appears in the app queue: a stale caller or
  simultaneous Next/prefetch must not lose fetched tracks.
- A failed, stale, cancelled or unsupported-settings startup preserves the
  current session and music queue. A successful explicit reseed replaces only
  upcoming tracks. Account logout invalidates all session/outbox data.
- Feedback is nested event + batchId, sent to its original server session.
  Keep an in-flight track's old context across batch fetches and reseeding.
  Bound pending events to 256; keep failed events and retry before refill.
  Errors are surfaced locally and no tokens/video/audio URLs are logged.
- Start events come from observed media advancement, not a selected favorite,
  screen mount or queue assignment. Sum small positive media-time increments;
  paused/buffering samples and seek discontinuities are not counted. A terminal
  event is emitted once per playback attempt, with this measured time, not the
  full nominal song duration. No duplicate skip from the presentation layer.
- Radio mode ignores saved playlist shuffle/repeat for forward selection.
  End of a short queue returns no next track until a real new batch arrives;
  a failed fetch does not wrap to the first song. User can retry Next/start wave.
- Signed-in mood cards and settings use this server pipeline. No hidden chart,
  favorite-seed fake start or UserTasteEngine reordering in Yandex wave.
  Explicit AI/local-vibe and Recap remain separate modes.

## Tests changed intentionally

The owner authorized fixing every audited wave issue. The old random-favorite
startup assertion and old comma-separated station queue assertion codified the
incorrect protocol; replaced with stronger server-session/order/no-fallback
checks and executable production-client fixtures. Audio/Beat Waves/EQ/haptics
pins are unchanged. Playback race guards remain.

Linux structural suite; macOS executable tests compile the real session client
and real PlayerCore next selector against stub HTTP. Cases cover five-track
exhaustion with all shuffle/repeat combinations, successive batches, duplicates,
server-order, malformed/status failures, unsupported settings, stale playback,
logout during refill, unknown session, cancellation, original feedback batch,
offline feedback retry, actual media-time accounting and duplicate terminal events.

## Required physical/account QA

CI fixtures cannot prove live Yandex behavior. Validate with a personally signed-in
account: 30+ consecutive tracks, rapid skip, background/lock-screen controls,
change filters while a request is in-flight, offline and recovery, account change,
Track Radio and ordinary My Wave. Confirm one server session across ordinary
refills and inspect WAVE diagnostics on any empty/unknown session response.
Do not claim zero lifetime repeats: server output and bounded history still matter.

## Expiry and leaving radio

Only an unknown/terminated server session is renewed during continuation. Keep
station, applied filters and queue history; retain the native playback-session
generation so normal refill race guards remain valid. Never restart for an
ordinary duplicate/empty batch. Preserve a final terminated batch until consumed.
Ordinary router/direct PlayerCore play exits radio; explicit wave play passes
`radio: true`. Leaving closes the server context after capturing a terminal event
and preserves its pending outbox. Logout instead discards it, so no old account's
event can be submitted with another account. A feedback 404 cannot block newer
sessions indefinitely.

## Published SessionEvent contract: explicit recommendation feedback

Reference: https://ym.marshal.dev/api/#description/introduction and upstream
`rotor/session_event.py`, `rotor/session_feedback.py` at the revision above.
The existing settings/new-session/continuation pipeline is retained, not replaced
with a random local playlist or an undocumented endpoint.

- Favorites still update the separate `/users/{uid}/likes/tracks` collection API.
  During a server wave, the same explicit user action also enqueues `like` or
  `unlike` recommendation feedback synchronously with its original batch/session.
  A collection response is not evidence that the recommender received feedback.
- The player menu sends `dislike` **before Next** with the actual accumulated media
  advancement, or `undislike` on undo. These events alone do not change favorites.
  Recommendation feedback is a preference, not a promise that the server will
  permanently ban every appearance of that track.
- `trackFinished`, `skip`, and `dislike` always include finite nonnegative
  `totalPlayedSeconds` (zero if no audio has advanced). Other supported track
  events do not include that field. Invalid event kinds, empty IDs, and tracks
  without a known wave batch are ignored rather than emitting invented feedback.
- Pending preferences retain their original timestamp and party on retries.
  A filter reseed does not redirect a playing track's feedback to the new session.
  Account reset discards the outbox; local/AI modes remain separate.

Executable Swift fixtures cover all four preference types, mandatory measured
seconds, nil/NaN/infinity/negative time sanitization, invalid events and unknown
tracks, old-session feedback after reseeding, and offline retry. Physical/live
account QA is still needed for recommendation changes; deterministic tests do
not predict Yandex's proprietary ranking.
