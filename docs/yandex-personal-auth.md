# Personal Yandex Music authorization in Sonivo

## Scope and provenance

This is an independent native Swift implementation of the OAuth Device Flow
contract described by **MarshalX/yandex-music-api**, not the Python library embedded
in iOS and not the official Yandex LoginSDK. Protocol reference pinned to upstream
commit `7d555bdd8b5e6a4a62665245c141cfbd99f0a9e7`:

- https://github.com/MarshalX/yandex-music-api/tree/7d555bdd8b5e6a4a62665245c141cfbd99f0a9e7
- `yandex_music/_client/device_auth.py`
- `yandex_music/device_auth/device_code.py`, OAuth token model, `_client/playlists.py`
- Upstream LGPL-3.0 license supplied in `ThirdPartyNotices/YandexMusicAPI-LICENSE.txt`.

As in the referenced library, the compatibility OAuth client identifiers are the
**publicly shipped identifiers of the official Android Music client**, not a Sonivo
OAuth registration. They are NOT a shared user access token. Their inclusion does
not confer official integration status, ongoing API availability, permission to
redistribute music, or App Store approval. The consent page may identify the
upstream client rather than Sonivo; the sign-in UI discloses this. A future supported
partner integration should replace this configuration. No user token or account
password is embedded, printed, committed, or passed through a proxy/backend.
No additional package/runtime dependency, no Python in the iOS app.

## Flow

1. Explicit user action requests `POST https://oauth.yandex.ru/device/code` with
   `client_id`, random `device_id`, and truthful unofficial Sonivo `device_name`.
2. Show `user_code`; open only the validated HTTPS `verification_url` on the
   allowed OAuth Yandex host (or exactly `https://ya.ru/device`, the live server's
   current short confirmation page), in the user's external browser. No WKWebView,
   WebAuthn suppression, token-fragment scraping, native passkey emulation, or
   automatic clipboard reads. Only the short user code can be copied by a button.
3. Poll `/token` using the exact upstream `grant_type=device_code`, `code` and
   OAuth client configuration. Respect server interval, increase by 5 seconds on
   `slow_down`, use a monotonic deadline, cancel on close/tab change/disappearance.
   Pending/denied/expired/invalid responses are handled without echoing raw bodies.
4. Stage the token separately. Verify `/account/status` using THAT token and a
   positive returned UID. A cancelled/stale/failed attempt cannot replace or save
   the previous account. Keychain save failure also keeps the previous session.
5. Save UID/access token/optional refresh token/expiry together in Keychain,
   `AfterFirstUnlockThisDeviceOnly`; update existing item without deleting first.
   Install the verified session atomically on MainActor, then sync metadata in
   the background. Missing Plus status is **false**, not a promise of Plus/FLAC.
6. Refresh shortly before expiry (60 seconds), one shared refresh operation,
   validate the refreshed token belongs to the same UID, preserve a refresh token
   if the response does not rotate it. Manual tokens without expiry/refresh rely
   on explicit re-login after rejection. Network failures are not credential
   revocation. A current-session 401 or invalid refresh grant disconnects it.

## Session and data boundaries

- Deleted the hardcoded common user token and every fallback reference (catalog,
  lyrics, artist resolver, requests, logout). Old `ym.token` in UserDefaults is
  removed, **not migrated**: old builds cannot establish its personal ownership.
  Upgrading from those builds intentionally requires a new explicit sign-in.
- The old token remains in Git history: its owner must revoke it in Yandex ID.
  Removing a source line does not revoke a credential. Never test/use it.
- Session generation and login-attempt identity guard in-flight responses,
  staged logins, refresh, like tasks, radio feedback and cloud imports.
- A replacement UID or logout clears radio session/batch/history/catalog caches,
  cloud favorites/imported playlists, cached profile and Yandex streaming queue.
  Active Yandex streaming is stopped. Local playback, local files and local
  favorites are retained. User-created local playlists are retained; only their
  old Yandex streaming references are removed. No music files are deleted.
- A locally imported filename containing numbers is NOT a Yandex identity.
  Cleanup requires `isStream` plus the canonical `ym_<id>.mp3` filename.
- Favorites: obtain the entire ID response, support up to 2000 tracks, resolve
  in batches of 200. Exceeding the cap or an incomplete/failed batch is a visible
  sync failure and does not replace existing favorite data. A valid empty library
  IS different from an HTTP/JSON failure.
- Playlists: list the logged-in UID's playlists and resolve full track metadata,
  up to 50 playlists / 2000 entries each. Import only when the whole response set
  succeeds; preserve old import on failure. Stable playlist identity includes
  UID and playlist kind. Imported playlists are **local snapshots**, not two-way
  playlist editing: adding/deleting/renaming the snapshot does not modify Yandex.
  Like/unlike retains the existing server synchronization path.
- No whole-track download is added to authorization/sync. Playback remains the
  existing streaming pipeline. DSP/EQ/beat detection and radio ranking algorithms
  are not changed. Radio requests now use the personal session; this is not a
  rewrite of the earlier rotor protocol/ranking audit.
- Personal account library/recommendations are NOT a transfer of the official
  Yandex application's current playback position/queue; that separate capability
  is not implemented or promised here.

## Validation

Linux: `python3 -m unittest discover -s .github/scripts -p 'test_*.py'`.
Eight added source regression tests in `test_yandex_personal_auth.py`.
The existing macOS compiled Swift test also invokes
`check_yandex_personal_auth.py`: actual OAuth transport with URLProtocol fixtures,
server errors, allowed login URLs, cancellation, form escaping, refresh/expiry
and credential serialization. No real user secrets/network required by fixtures.
Full iOS Swift 6 strict-concurrency archive / IPA in `build-ipa.yml`.

### Manual iPhone checks (not substituted by CI)

1. Open Settings → Yandex Music → sign in by code. Confirm browser/code/consent
   account, return to app, verify exact login/avatar and personal favorites.
2. Restart app, sync favorites and playlists; confirm saved session restores.
3. Like/unlike a track and check the SAME account in Yandex Music.
4. Deny, allow code to expire, close sheet while waiting/validating, switch tabs;
   no late successful login after cancellation. Retry obtains a fresh code.
5. Switch between two accounts; old favorites/playlists/queue disappear, delayed
   old imports cannot reappear. Local imported files/favorites remain.
6. Offline / expired token / revoked access: explicit failure or re-login; no
   common-account fallback. Check refresh where account supports Device Flow.
7. Personal My Wave / track radio uses new credentials, without promising the
   official app's exact queue or changing ranking. Verify supported streaming
   quality against account/region/subscription rights, not UI labels.

Live Device Flow/account permissions, subscription, real token refresh and server
behavior remain unverified until an owner performs this authorized device test.

## Device verification URL regression

A live unauthenticated `/device/code` contract check returned HTTP 200 and
`verification_url: https://ya.ru/device`, `expires_in: 300`, `interval: 5`. The
original OAuth-only URL allowlist rejected that valid response before displaying
the code. The correction permits `ya.ru` only at `/device` or `/device/`, still
HTTPS-only, without userinfo or explicit ports. Exact-host matching rejects
`ya.ru.evil.test`, and other paths on `ya.ru` remain forbidden. Added real Swift
URLProtocol coverage for the short URL plus rejection fixtures. No device codes,
user codes, user tokens or response bodies were logged/persisted by this contract
check; it did not authenticate any account. Actual consent/token exchange still
requires the user to complete sign-in on their device.
