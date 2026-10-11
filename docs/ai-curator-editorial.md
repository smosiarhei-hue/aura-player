# AI Curator — music editorial

## What the screen does
- Current-song discovery: sends title and artist only with the explicitly enabled metadata toggle. Audio is not analysed/uploaded.
- Activity / mood: starts an editable request, not a hidden radio mode.
- Discover something new: visible, explicit alternative-electronic discovery prompt; not a claim of knowing the user's taste.
- Own idea: free text with the previous 12 bounded turns for clarification.
- AI suggests 12–20 songs by default; a separate extension asks for up to 50. Neither quantity nor catalog availability is guaranteed.
- Exact normalized artist/title and availability are checked in the signed-in music catalog, four concurrent searches maximum, 60 recommendations maximum per response. Wrong remixes/first search hits are not substituted. Strict matching may miss valid alternative spellings; missing matches are shown honestly.
- No chart/library padding; no client-side My Wave ranking or changes to its session algorithm.
- Guest mode can discuss music with a configured personal AI provider but cannot fetch/play remote catalog songs. After login, repeat a request to resolve it for that account.

## Ownership and lifecycle
- Store owns one cancellable operation. UUID lookup after every await prevents stale chat-index mutations.
- Clear, dismissal, account changes and provider configuration changes cancel pending work. Requests verify cancellation/account/configuration before committing.
- Chat archives are bounded to 60 messages and scoped to music-account UID or local guest mode. Old unscoped v1 archives are not auto-imported into an arbitrary account; old data is left untouched.
- Saved playlist ID is persisted on the message. Saving is idempotent while that ID exists; duplicate titles never select the wrong library playlist. Library creation receives tracks once, not twice.
- Extensions exclude current catalog IDs and normalized artist/title; update the saved playlist by ID. Actual additions, not a guaranteed +50, are displayed.
- Toast notices never change the clipboard. Only explicit copy operations do.

## Provider and privacy
- Keys migrate from legacy UserDefaults to device-only Keychain. Two retired shared-key fingerprints are rejected; there are no usable shared API-key literals in this implementation.
- **Repository owner must revoke the previously shipped shared NVIDIA/Dify keys in the provider accounts.** Removing source literals does not revoke them or remove Git history. This agent did not use/revoke those keys.
- User supplies HTTPS endpoint, personal key and (NVIDIA) an exact model ID from their account. No marketing model list, fallback-model retries, or silent retries after auth/cancellation errors.
- The external AI provider receives requests and bounded conversation text. Explicit metadata consent adds title/artist. Extension sends up to 200 existing artist/title entries; all existing IDs/names are still excluded locally.
- PCM, audio files, favorites and listening history are not sent by the curator. Personal provider policies/billing still apply.
- Dify curator conversations are isolated from video, DJ, extension and health requests; changing account/configuration clears the local conversation reference. NVIDIA receives bounded chat history. Private reasoning deltas are not displayed/persisted.
- HTTP auth/rate-limit errors, SSE error events, empty answers and oversized streams surface typed messages.
- No automatic notification-permission prompt or automatic AI calls when opening the screen.

## Native UI / motion
- Existing offline Sonivo wordmark plus scalable native editorial typography; semantic surfaces, native Liquid Glass composer/connection card, 44-point targets.
- One-shot 450 ms reveal and 250 ms status transitions. Decorative working bars max 24 fps, paused in background/off-state; static with Reduce Motion and hidden from VoiceOver.
- No runtime web animation libraries or new dependencies; no audio DSP/physics/EQ changes.

## Verification
- Linux structural tests: honest selection, idempotent save, UUID cancellation guards, account archive bounds, credentials, channels, HTTPS, metadata opt-in, native motion, guest gating, clipboard.
- macOS fixture executable compiles actual policy/models/transport/resolver/store: exact/wrong-remix matches, guest resolution, clear during suspended request, account switching, save IDs, clipboard preservation, HTTP 401 single request, Dify SSE error and isolated channel state.
- Fixture responses contain no real account/provider credential. Native layout, physical haptics, provider billing/availability and real catalog matching require owner testing on iPhone with a personal key.

## Automatic model setup and intent contract
- Saved provider/key/endpoint/model are reused. Settings load the NVIDIA `/models` catalog with the personal key; no API keys are obtained from the music login.
- The normal model choice is automatic. Existing selected models remain selected. Advanced settings still allow a custom HTTPS endpoint/exact model ID when a provider does not support catalog listing.
- Auto selection excludes obvious embedding/reranking/audio/image/safety-only IDs, preserves a suitable existing ID, then selects a deterministic chat/instruct candidate from the returned catalog. Names are only hints, not proof of capability/access.
- A blocking chat health probe must return nonempty content before credentials/model are committed. Catalog access alone is not claimed as a verified connection. Failed/cancelled setup preserves the previous connection; no blind alternate-model retries.
- Dify uses its server-configured app/model, not a client-invented model ID. Its isolated health request is verified before saving; it does not overwrite the curator conversation.
- Setup fields cannot change during an operation; Stop/Close cancel it. Keys are not logged.
- The improved editorial prompt distinguishes playlist, clarification and conversation, including implicit requests such as music for an activity and follow-up edits. It prioritizes exclusions/latest edits, asks one question only when material information is missing, and does not invent audio analysis or user history.
- Structured responses include intent and a visible “Понял запрос так” summary. Clarification/conversation cannot be interpreted as a playlist even if an erroneous playlist field is present. Empty/invalid structured replies are rejected. Existing flat-playlist responses remain compatible.
- Bounded conversation context retains the previous clarification and suggested artist/title pairs. New Dify conversations receive the local bounded context after relaunch; existing Dify conversations retain their server context.
- These are contract/transport/prompt tests, **not a claim of 100% semantic accuracy**. Real model quality and catalog match rates still depend on the request/provider/model and need owner evaluation.
