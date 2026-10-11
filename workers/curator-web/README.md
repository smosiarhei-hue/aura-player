# Optional curator web proxy — legacy/private server template

**Current Sonivo personal-key flow does NOT require or call this worker.** The app now accepts only a personal Firecrawl API key and calls the standard API directly. This module is retained as an optional future backend template for app-funded shared keys. Do not deploy it merely to use the current AI Curator.

Optional Cloudflare Worker + Durable Object. No production URL/credentials are shipped, and nothing is auto-deployed.

1. Install/use Wrangler in your own Cloudflare account and run commands inside this directory.
2. `wrangler secret put FIRECRAWL_API_KEY`: enter your Firecrawl key in the private terminal prompt.
3. Generate a distinct random access token of at least 32 characters (e.g. `openssl rand -hex 32`), then `wrangler secret put CURATOR_ACCESS_TOKEN`.
4. `wrangler deploy` provisions the `SearchGate` Durable Object via the migration.
5. Connect a separately implemented backend client to `https://YOUR-WORKER.workers.dev/search` with its access token. Current Sonivo builds intentionally do not expose a custom server-address field.

Do not post either secret in chat. A backend-mode client must store only the server access token in device-only Keychain; current Sonivo stores its owner-supplied upstream Firecrawl key instead. Do not embed a shared access token in builds. This is a private single-owner deployment. Before public multi-user distribution replace bearer authentication with verified per-user identities, quotas and revocation. A Yandex session is never sent here and must not serve as Firecrawl authentication.

Contract: POST `/search`, Authorization Bearer, JSON `{"query":"..."}` (1–1000 chars). Response `{"sources":[{"title":"...","url":"https://...","excerpt":"..."}]}`. Maximum three sources with 3000-character excerpts. Errors: 400/401/415/429/502/503, with sanitized codes only.

Firecrawl v2 `/search`: limit 3, web only, safe search, main-content Markdown, 15s upstream timeout +18s hard timeout. No arbitrary upstream URL, caller actions, caller formats, Yandex headers or AI keys are accepted. HTTPS public-domain links are returned; full response capped at256KB. Search+scraping is billable according to Firecrawl's current plan, not necessarily one credit per request.

Persistent deployment-wide budget:60 upstream attempts/day and12/minute, counted atomically before network, including failures. Identical searches reuse15-minute cache, maximum60 entries. Cache contains query-derived hashes and excerpts, never accounts/tokens; Firecrawl necessarily receives query text. Disable Cloudflare request-body logging and choose retention appropriately. No application query/secret logging is implemented.

`node --test test/*.test.js` runs offline fixtures, not live Firecrawl. Cloudflare account/plan restrictions and real service credentials must be tested by the owner after deployment.

Official API: https://docs.firecrawl.dev/api-reference/endpoint/search
