# My Wave continuity and playback checkpoints

Reference: MarshalX/yandex-music-api `_client_async/rotor_sessions.py`
https://github.com/MarshalX/yandex-music-api/blob/master/yandex_music/_client_async/rotor_sessions.py

- `/rotor/session/new` receives seeds and previous queue IDs; `/rotor/session/{id}/tracks` receives all already received IDs. Do not restart a live session on each refill.
- Track IDs with `:album_id` suffix share the same exclusion identity. All received IDs (including unavailable/disliked entries) enter the bounded 1000-ID API queue. No local reranking, chart fallback or shuffle.
- At most three empty/duplicate/unavailable batches per request. A new session replaces the old one only after it has playable entries and still owns the request/account generation. Only server `unknownSession`/`terminated` renew an existing session.
- Renewal includes recent listening history and the current queue, not just the latter. Actual media advancement owns trackStarted/finished/skip feedback and original batch context.
- After the existing one legacy-source recovery and offline-cache fallback fail, Wave alone skips a broken track. Skips are not dislikes. Five consecutive automatic skips maximum; two seconds of actual listening resets the consecutive counter. Failed IDs remain excluded in this playback context. Pause/new queue/account guards reject delayed work.

## Resume

Track metadata, a current-centered queue window (up to 60 entries), account owner and Wave station intent are saved at playback boundaries, seek, pause and scene inactivity/background. Progress checkpoints update at most every two seconds from existing media clock samples; no per-frame JSON serialization. Resolved catalog stream URLs are stripped. Local missing files and other-account streams are not restored.

Restoration runs once after initial account restoration completes, paused with the last position; it never activates the audio session or starts music by itself. Pressing Play resolves a fresh source and seeks to that position. Restored Wave queues retain their no-shuffle/no-wrap behavior; continuation starts a fresh server session with history, never reuses a persisted server session ID or invents old feedback context.

Normal closure/background checkpoints the last sampled position. OS termination without lifecycle callbacks can lose approximately the final two seconds; exact last-sample durability cannot be promised. UserDefaults persistence is not an atomic audio transaction.

Regression coverage includes executable production session, selector, checkpoint and source-skip code on the macOS Swift 6 CI runner. Real account streaming, device suspension, decoder failures and audible continuity still need iPhone testing; passing CI is not a claim of universal Yandex availability or zero repeats of recordings published under distinct track IDs.
