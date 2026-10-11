# Curator — bounded live inference evaluation

## What was actually exercised
Personal NVIDIA and Firecrawl credentials were supplied by the owner solely for authorized connection/evaluation calls. They are not bundled in the app, fixtures, repository or report. Rotate both exposed chat credentials; enter fresh personal keys on the device (Keychain).

Live NVIDIA model: `nvidia/nemotron-3-super-120b-a12b`, returned by the authenticated catalog and callable in the agent's environment. This does not prove iPhone/Belarus connectivity or best quality among all models.

Four scenarios were evaluated against the production system-prompt text:
1. Five songs for a calm evening walk, no heavy rock.
2. Follow-up: four softer instrumental songs, no repeated artist/title pairs.
3. Five youth hits from original releases 2000–2009, excluding 2010s.
4. Five similar instrumental songs by other artists, reference Bill Evans — Peace Piece.

Each generation returned HTTP 200. Final four-case pass produced valid JSON with the requested 5/4/5/5 counts, nonempty artist/title/reasons, no within-list duplicates, no old pairs in the follow-up and no reference artist in the similar-song list. Firecrawl returned three sources for each initial query. These are **structural/protocol checks, not semantic success scores**.

An earlier run returned an unparseable era answer with a smaller evaluation-only 2200-token cap. The harness now uses 4096, matching the production generation cap, and records parse success / finish reason. That later answer finished normally; this is not evidence that every future answer will do so.

## Quality findings, not hidden as “100%”
- Similar-song replies initially drifted to composer-only classical works and an album-prefixed invented recording title. Tightened the instructions to stay in jazz piano for that reference unless crossover is requested, distinguish recording performer from composer, and omit album prefixes. Added concrete editorial examples and a separate follow-up probe. That probe returned five suggestions and moved toward jazz, but still produced an album-prefixed Jarrett title and questionable album/title metadata for other artists. The exact catalog guard is therefore essential; the prompt does **not** fix these errors reliably. Removed the literal bad title example from the final prompt to avoid teaching the output we meant to prohibit. That final wording adjustment was not separately benchmarked.
- Even plausible AI reasons may contain factual errors; sources may include weak or blocked pages. The model is explicitly told not to obey retrieved-page instructions or invent verification. Web retrieval alone does not establish a song's catalog presence, release date or acoustic similarity.
- Era examples included OutKast — Hey Ya!, The Killers — Mr. Brightside, Gnarls Barkley — Crazy, Rihanna — Umbrella, Kanye West — Stronger. Independent original-release research was not performed in this evaluation. The app additionally applies a conservative metadata year filter.
- Instrumental-vocal constraints and similarity require listening/acoustic data or human evaluation. No audio was sent/analyzed here.
- No live Yandex token was available in this evaluation. Catalog resolution is covered by compiled fixture tests and must still be exercised with the owner's signed-in music account on iPhone. Counts can drop after exact catalog/year verification; no unrelated fillers are added.
- No autonomous subagent platform or fine-tuning job was used. This is bounded real inference + retrieval + deterministic catalog guards, not weight training or access to private music history.

## Repeat safely
Set `NVIDIA_API_KEY` and `FIRECRAWL_API_KEY` through a private environment, not committed files or command examples containing real values. Run `python tools/curator_live_eval.py`. Optional `CURATOR_EVAL_SCENARIO` is `walk`, `era` or `reference`; walk also tests one follow-up. Optional `CURATOR_EVAL_OUTPUT` chooses a local results path. Billing applies. Do not commit real transcripts automatically.

## Follow-up: Basta reference / extension fixes
A single optional `basta` scenario uses **Баста — Сансара** as a concrete evaluation example (the owner mentioned Basta but did not specify a track title). It requests five other-artist songs, at most two per artist. The first live probe passed JSON/count/excluded-artist checks yet was **semantically wrong**: it inferred “eastern motifs” and suggested thematic-title matches. Retrieved results mostly concerned disputed melodic borrowing/social videos. This was not counted as a quality pass.

Corrected production search/instructions to prioritize actual song character rather than literal title meaning, artist discography or plagiarism comparisons. Original request/reference now also survive “Дополнить”. Deterministic seed exclusion and a two-recording artist cap cannot be bypassed by an AI instruction-following failure. Release/version/exact recording checks remain. A second live probe is documented below separately; no live Yandex catalog or acoustic comparison was performed.

Second Basta probe returned HTTP 200, five suggestions from five different artists, no Basta, valid JSON and a melancholic/reflective rather than “eastern motifs” interpretation. However, it still produced dubious recording metadata such as a shortened Би-2 title and mixed-language “Город 312 — Ты не alone”, and claimed an acoustic version not identified in the title. **Not a semantic/factual quality pass.** No title was silently repaired or replaced with the first search hit; catalog guards must reject those mismatches. Fewer than the requested number can still remain after verification. This follow-up improves context/diversity/latency structure, not the model's factual reliability or an acoustic benchmark.
