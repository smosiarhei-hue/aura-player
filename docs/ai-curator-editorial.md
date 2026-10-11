# AI Curator — music editorial

## What the screen does
- Current-song discovery: sends title and artist only with the explicitly enabled metadata toggle. The paperclip also allows an explicit current/library song reference, independent of that toggle. Audio is not analysed/uploaded. The selected reference is cleared on music-account change.
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
- User supplies a personal key; standard provider endpoints are prefilled. NVIDIA has bounded automatic curator-contract verification or an explicit manual model. See `ai-curator-model-selection.md`; auth/cancellation failures do not silently switch models.
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
- Automatic selection is quality-oriented and bounded, not a benchmark or a guarantee of best semantic quality. Catalog membership alone is insufficient: candidates must pass a curator JSON contract probe. See `ai-curator-model-selection.md` for actual priorities, deadlines and stop conditions.
- Dify uses its server-configured app/model, not a client-invented model ID. Its isolated health request is verified before saving; it does not overwrite the curator conversation.
- Setup fields cannot change during an operation; Stop/Close cancel it. Keys are not logged.
- The improved editorial prompt distinguishes playlist, clarification and conversation, including implicit requests such as music for an activity and follow-up edits. It prioritizes exclusions/latest edits, asks one question only when material information is missing, and does not invent audio analysis or user history.
- Structured responses include intent and a visible “Понял запрос так” summary. Clarification/conversation cannot be interpreted as a playlist even if an erroneous playlist field is present. Empty/invalid structured replies are rejected. Existing flat-playlist responses remain compatible.
- Bounded conversation context retains the previous clarification and suggested artist/title pairs. New Dify conversations receive the local bounded context after relaunch; existing Dify conversations retain their server context.
- These are contract/transport/prompt tests, **not a claim of 100% semantic accuracy**. Real model quality and catalog match rates still depend on the request/provider/model and need owner evaluation.

## Reference / era refinement
- Explicit song references are archived with a user message and carried into bounded follow-up context. Web search includes the selected artist/title, not just a generic context header. The picker uses cancellable off-main library projections, lazy rows, account-generation ownership, a 100-row cap and searchable filtering.
- Requests distinguish activity, similar-song discovery, explicit original-release decades, stylistic references and follow-up exclusions. Examples guide inference; **no model weights were trained or fine-tuned**.
- Explicit year ranges and decades such as 2000–2009 are persisted on the answer and reused for extensions. A concrete new task or an explicit any-year instruction stops inheritance. Stylistic “in the style of the 2000s” is not automatically treated as a release-date limit.
- Resolver checks exact normalized recording title, separately supplied version, primary/full artist and availability. When a period is requested it uses the earliest known album year from catalog metadata. Unknown/out-of-period metadata is rejected. This is a catalog proxy: it cannot prove original recording year when the catalog contains only a reissue. The UI warns that valid reissues/missing years can be skipped.
- Reasons are displayed alongside exact matching recommendations. No guarantee of vocal content, BPM, perceived similarity or availability is derived from AI prose.
- Live evaluation is opt-in (`tools/curator_live_eval.py`), uses credentials from environment only, 3 searches + 4 generations by default, and supports a single named scenario. Recommendations/web sources are public data; keys/raw provider responses are not written. The check is inference/retrieval, not training. See `curator-live-evaluation.md` for observed results and remaining quality limitations.

## Vibe discovery and bounded extensions
- “Similar to the attached/current song” defaults to other artists, not the seed artist's discography. Explicit same-artist/discography requests can opt out. Rules are archived on the assistant message and carried into relevant follow-ups/extensions; a new attachment replaces old rules.
- Excluded seed artists are filtered from draft suggestions, from catalog artist lists (including collaborations), and again from final tracks. Cyrillic-to-Latin normalization catches simple spelling variants such as Баста/Basta, not all aliases (e.g. different stage names).
- Discovery permits at most two recordings per normalized primary artist across the entire selection. This is enforced after exact resolution and includes existing songs when extending. Collab name suffixes do not bypass the primary-artist counter. These guards do not prove perceived acoustic similarity.
- Extensions retain the original user request, selected reference, period, diversity rules and already proposed recordings, including unresolved suggestions. Old archives without assistant-side request fields recover the preceding user reference where available. Context lost through clearing archives cannot be reconstructed from a playlist title alone.
- Default extension is **up to 10 suggestions**; curator menu offers 20 or 50 explicitly (larger requests take longer). Each operation makes one AI generation, no blind retry or chart padding. Up to four catalog lookups concurrently, with duplicate/excluded/already present candidates removed before network calls.
- Curator catalog lookup is a dedicated `/search?type=track&nocorrect=true`, no global artist/album enrichment or music-library synchronization. It requests the first page, uses a 15-second request timeout and a 2MB post-download decoding guard. Default ten candidates require fewer calls than fifty; no phone latency measurement or universal response-time guarantee is claimed.
- During catalog lookup the curator shows completed/total counts. A separate last-extension result shows actual added vs suggested. Missing matches, unavailable records, diversity exclusions and duplicates may make the result smaller. Typed per-reason lookup-error diagnosis is not yet implemented; the UI does not claim all misses are catalog absence.
- Extensions from the library use the archived curator context where available and record outcomes back to an idle curator. Before committing, both entry points re-read saved playlist contents and apply duplicate/diversity checks against the latest state.
- Similarity instructions/search distinguish song character from literal title words, artist-wide stereotypes and plagiarism/news comparisons. Reference searches prioritize genre/mood/arrangement and exclude short social-video sites/“plagiarism” keywords. This is retrieval guidance, not factual acoustic verification.
