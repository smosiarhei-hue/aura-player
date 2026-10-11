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
