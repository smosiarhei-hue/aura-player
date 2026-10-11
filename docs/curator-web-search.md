# Optional web-grounded AI curator

Sonivo connects to a personal authenticated Firecrawl proxy, not directly to Firecrawl. No shared credential, deployed URL or paid request is included in this change. Owner deployment instructions: workers/curator-web/README.md.

## User flow
- Configure HTTPS `/search` proxy URL and a distinct server access token in AI settings. Token is stored in device-only Keychain; Firecrawl key stays on server.
- Explicitly enable web search (off by default). The toggle states that query text, one previous user clarification and optionally consented song title/artist go to the server/Firecrawl. No account token, audio, favorites or listening history is sent.
- Curator shows searching → AI reply → catalog resolution, within the same cancellable operation.
- Build requests and conversational answers get up to3 bounded source excerpts. Follow-up playlist extensions also retrieve fresh context, with the existing exclusion/duplicate policy unchanged.
- Source URLs/titles/date are rendered separately from model text. They are actually retrieved candidates, not proof every claim/track came from that page. Prompt requests numbered [1] citations but does not guarantee model compliance.
- No sources/quota/HTTP/network failure produces an explicit “without fresh web data” notice, then continues the ordinary AI request. It must not claim an internet search took place when disabled or failed.
- Stop, clear, account changes and settings changes cancel/discard stale work. Source metadata survives chat archive reload; older archives decode optional fields.

## Boundaries
Retrieved text is serialized data, never a system instruction; system prompt rejects page-injected commands/secret exfiltration and distinguishes release facts from catalog availability. This is defense in depth, not a promise of complete prompt-injection immunity or100% answers. AI remains advisory; the existing exact artist/title resolver is the only source of playable account tracks. No change to My Wave, VideoShots, audio engine or library sync.

## Verification
Offline Node tests: auth/body contract, fixed upstream, safe public source URLs, truncation, deduplication, sanitized errors, response size, persistent atomic budgets and bounded cache. macOS Swift transport/store fixtures exercise opt-in, HTTP/auth/quota, bounded response, source context into AI, exact catalog resolution, visible fallback, archives, cancellation and zero web traffic when disabled. CI does not verify production Firecrawl credentials, Cloudflare deployment or factual music recommendations.
