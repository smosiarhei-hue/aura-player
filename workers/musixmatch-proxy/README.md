# Sonivo Musixmatch proxy

First-party Cloudflare Worker that keeps the official Musixmatch partner key off-device.
It exposes only an allow-listed set of read-only endpoints used by Sonivo.

## Deploy

1. Run `wrangler secret put MUSIXMATCH_API_KEY` and enter the official partner key.
2. Deploy with `wrangler deploy`.
3. Set the resulting HTTPS URL in Sonivo → Settings → Musixmatch proxy.

Never commit the API key or ship it inside the iOS application. The proxy validates route parameters,
checks Musixmatch response status, and caches successful responses for five minutes.

## Routes

- `/search?artist=&title=`
- `/matcher/lyrics?artist=&title=`
- `/matcher/subtitle?artist=&title=&format=lrc`
- `/track/search?q=&title=&artist=&lyrics=&page=&page_size=`
- `/track/{id}` or `/track/get?track_id=|commontrack_id=|isrc=|spotify_id=`
- `/lyrics/{id}` and `/lyrics/{id}/translation?language=`
- `/snippet/{id}`
- `/subtitle/{id}?format=lrc`
- `/subtitle/{id}/translation?language=&format=lrc`
- `/richsync/{id}`
- `/chart/tracks?country=&page=&page_size=`
- `/artist/search?artist=&page=&page_size=`
- `/artist/{id}`
- `/album/{id}`
