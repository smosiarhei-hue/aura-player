# Spotify catalog source (wolfXspotify)

Settings → Musical catalog → Search source selects only the Search tab. Default and invalid saved values resolve to Yandex/local. Account, My Wave, favorites, cache, audio quality, mini-player, current item and queue retain their original owner. Switching away tears down the catalog screen and cancels its SwiftUI tasks. It does not sign out or stop playback.

This is **not a Spotify playback backend**. Full tracks, Premium login, 320 kbps/lossless streams and automatic Spotify→Yandex ID matching are deliberately not implemented. Search results open a detail sheet with an official Spotify HTTPS link and, only when available, an explicit external-browser preview link. Opening external apps/browser may affect audio according to OS behavior, not this API client.

Schema reference: https://github.com/WOLVAREX/wolfXspotify-API (src/routes/search.js, src/routes/track.js). Independent adapter; no server source, token generation or shared anonymous credentials are bundled.

- Only `/api/search?q=…&type=track&limit=20` and `/api/track/:id` are requested.
- Separate ephemeral URLSession, no cookies, no cache, no auth headers, no Yandex keys/tokens.
- Search query is sent to the third-party provider only after explicit provider selection and user search. Settings disclose the destination.
- 350 ms debounce; task cancellation checked before publishing. Empty queries make no request.
- 12-second request/18-second session resource timeout; response decoding capped at 2 MiB, results deduplicated/capped at 20.
- 404 search → empty results, 429 → rate-limit message, other failures → visible retry. No hidden audio fallback or quality substitution.
- Links are built from validated 22-character Spotify IDs, not arbitrary returned navigation URLs. Previews accept credential-free HTTPS scdn.co hosts only. Artwork accepts credential-free HTTPS.

Validation: `.github/scripts/test_spotify_catalog.py` includes a macOS executable fixture against the production Foundation client with URLProtocol mocks. On-device verification: switch while Yandex plays; queue/time should remain; search/cancel/switch rapidly; test unavailable provider/retry; return to Yandex; guest local search must remain available with the default provider. A live public track lookup returned HTTP 503 during review: metadata availability and previews cannot be guaranteed.
