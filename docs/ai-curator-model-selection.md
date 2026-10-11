# Verified curator-oriented automatic model selection

## Why changed
A live owner-authorized key check showed NVIDIA's catalog could include model IDs whose completion endpoint returned404. A current `nvidia/nemotron-3.5-lightning-30b-a3b` probe succeeded. Catalog membership alone is not API-key validation or proof a model can serve chat. The exposed key is not stored in code, fixtures or this document. The owner was advised to rotate it.

## Automatic selection
Only on explicit “Подключить и проверить” with automatic selected:
1. Fetch current catalog (45s deadline). Remove duplicates and obvious embedding/audio/image/vision/safety/reward/code-specialist/document-parser candidates.
2. Intersect catalog with a curator-oriented preference order (current general-purpose families). The preference order is a product heuristic, not measured best-model ranking or a promise of factual accuracy. Unknown general chat models remain eligible when the preferred families are absent.
3. At most3 different probes; reserve a candidate slot for current lightweight Lightning family if present. No ID absent from the catalog is invoked. One successful earlier candidate ends selection.
4. Verify a tiny fixed music-editing task: produce exactly one provided artist/title in the curator JSON envelope. Validate intent,summary,question,one-track count and exact normalized artist/title. Plain OK,empty/reasoning-only output,malformed JSON or changed/extra tracks do not pass. This tests basic output contract/constraint following, not broad music knowledge,playlist quality,live catalog matching or benchmarks.
5. Recover from model-specific400/404/410,empty/invalid-format or model timeout only.401/403,429,network/global service errors or provider error bodies stop immediately; no paid retries across these failures. Explicit model choices perform exactly one probe and are never silently substituted.
6. Per automatic probe up to60s; all probes together120s after catalog retrieval. Reserve30s for each later candidate so two slow probes cannot consume the last candidate’s whole time budget. Deadline/Stop/account/configuration guards are enforced. Probe output capped384tokens/256KB. Supported current Nemotron family gets thinking disabled for the compact connection probe only; real chat still uses the normal provider request. No user account/history/songs are used in the fixed probe.
7. Commit key+actual verified model only after success. Exhaustion lists safe candidate/status summaries; previous working connection remains unchanged. UI shows candidate1/3 etc,possible billing and Stop. Auto/manual selection preference is remembered, and auto stays selected after successful connection. Reopening/relaunch alone does not trigger billable re-selection or change saved actual model.

## Verification
Native production transport fixtures:404 then invalid OK then valid curator JSON chooses third candidate; candidate ordering/intersection/3-request cap; explicit404 no alternate; bad-key/quota/service stop; all-candidate failures preserve key; deadlines,cancellation and stale revision protection. Existing curator/account/web/audio tests remain. Offline fixtures do not prove a live preference ordering is objectively best or that every remote model supports a particular key/region.

## Not changed
AI provider health/video/DJ channels,account authentication,My Wave,audio engine,EQ,library. Administrator-only settings still await owner-approved account identity; no first-user/admin-by-installation shortcut is added.
