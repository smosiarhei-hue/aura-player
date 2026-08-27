# Sonivo AI Worker

Cloudflare Worker that securely keeps the Gemini API key server-side and ranks only catalog candidates supplied by the Sonivo iOS app.

## Required Cloudflare secrets

- `GEMINI_API_KEY`
- `APP_TOKEN`

Optional text variable:

- `GEMINI_MODEL=gemini-2.5-flash`

## Workers Builds settings

- Production branch: `main`
- Root directory: `cloudflare-worker`
- Deploy command: `npx wrangler deploy`

The Worker name in Cloudflare must be `sonivo-ai` to match `wrangler.jsonc`.

## Endpoints

- `GET /health`
- `POST /rank` with `Authorization: Bearer <APP_TOKEN>`
