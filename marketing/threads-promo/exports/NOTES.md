# Sonivo Threads reel — notes (2026-11-03)

Source: Google Drive capture (`1gj1MTmwwXXY6v9WL3ows684ofVInCtnW`), saved as `raw/sonivo-demo.mp4` (~2m35s, 880×1920, 59 fps).

## What shipped

| File | Use |
|------|-----|
| `sonivo-threads-9x16.mp4` | Threads / Reels vertical (~30s) |
| `sonivo-threads-4x5.mp4` | Alt crop 1080×1350 |
| `stills/` | Reel frames + carousel 4:5 JPGs |

Structure: title → splash/home → Now Playing → lyrics → wave scroll → 10-band EQ → сведение flash → end card.

Rebuild: `./scripts/build-reel.sh raw/sonivo-demo.mp4`

## Gap — need a retake

**AutoMix mashup (`MIXING` → stems → LAND) is not in this recording.**  
Settings show «переходы», and ~02:22 flashes «Сведение» into wave-by-track — but there is no dual-track mashup UI and no audible crossfade/mashup (same track plays the whole time).

### Retake checklist (2–3 min)

1. Queue two tracks; seek A to ~dur−25 s.
2. Wait for AutoMix — do **not** tap Next.
3. Capture visible `MIXING` / mashup chrome and LAND onto B (~12–18 s).
4. Optional: drag 2–3 EQ bands by hand.
5. Drop new file in chat or `raw/sonivo-demo.mp4` → rebuild.

## Threads copy (ready)

```
SONIVO

Плеер, который сводит треки — не просто жмёт «далее».

AutoMix Mashup · Моя волна · 10-band EQ · lyrics

Смотри переход в видео ↓
```

*(Swap the last line after the AutoMix retake lands.)*
