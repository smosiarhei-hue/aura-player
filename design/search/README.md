# Search contract and immediate input

References (unofficial Yandex API, not an official partner SDK):
- https://github.com/MarshalX/yandex-music-api/blob/master/yandex_music/_client_async/search.py
- https://github.com/MarshalX/yandex-music-api/blob/master/yandex_music/search/search.py
- https://github.com/MarshalX/yandex-music-api/blob/master/yandex_music/search/search_result.py
- https://github.com/MarshalX/yandex-music-api/blob/master/yandex_music/search/best.py

GET /search uses text, type, page, nocorrect, playlist-in-best. Supported UI types
are all/track/artist/album. Query punctuation is preserved; URLComponents encodes
it once. Whitespace is normalized. Automatic correction is shown from
misspellCorrected/misspellResult, with an explicit original-query action.

Results preserve native server relevance; artist-prefix and newest-album sorts
are removed. A supported best.result missing from its block is included on page 0.
Artist IDs accept integer or string. Category totals/perPage drive pagination;
merged pages deduplicate IDs while retaining server order. Curator-only strict
search and all playback selection behavior remain separate and unchanged.

The UI uses a visible native TextField with FocusState. The selected Search tab
activates input on the next view-tree yield, without timed animation delays or a
second searchable-bar expansion. This applies to Yandex, local and Spotify
catalog routes. This does not claim remote UI/device testing of repeat-selected
native tab taps or keyboard animations.

Typing debounces 250 ms; submit/filter retries are immediate. Request UUID,
cancellation and account generation block stale query/account results. Suggestions
run concurrently and do not block publishing music results. Recent searches are
saved after successful requests, not for every intermediate typed prefix.
Errors distinguish unavailable/authentication/rate-limited service from empty
search results. Query text, tokens and response bodies are not diagnostic logs.

Acceptance on an authorized iPhone: tab opens input, artist + title, exact title,
typo correction/original retry, category filters, next page, rapid query replacement,
clearing, offline, account change, playback from results, Dynamic Type and VoiceOver.
CI contract fixtures are not a live search test on the owner's Yandex account.
