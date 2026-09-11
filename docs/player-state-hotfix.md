# Player state hotfix

## Problem

When AutoMix V2 was enabled, presentation code always read V2 state even if a local or legacy playback path actually owned the audible track. Audio could therefore play while the mini-player and full player showed no track, timeline, or usable transport controls.

## Resolution

- Resolve the active owner from actual playback state, not only the feature flag.
- Prefer V2 only when V2 has a current track.
- Fall back to `PlayerCore` for local/legacy playback.
- Route play/pause/next/previous/seek to the engine that owns the audible track.
- Keep the mini-player visible for either owner.
- Treat V2 next-track prefetch as background work, not as current-track loading.

## Acceptance

1. Start a local downloaded track with AutoMix V2 enabled: metadata and controls remain visible.
2. Start an online track: V2 metadata, duration and position update.
3. Pause, seek, next and previous affect the audible engine.
4. Switching between local and online queue items does not leave stale artwork or an empty player.
