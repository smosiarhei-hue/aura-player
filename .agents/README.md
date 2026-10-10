# Project-local motion skills

Installed under `.agents/skills/`, with full references/scripts for the selected skills. This directory is generated, not a native app dependency. Reinstall the exact reviewed snapshots with:

```bash
python3 scripts/install_motion_skills.py
```

The installer verifies the pinned archive and every installed file against `agent_skills/motion-skills.lock.json`; it does not execute third-party scripts. License notices are in `.agents/vendor-notices/`. Selective install: HyperFrames motion/creative/core/registry/CLI/media references, Emil animation review/Apple design/Swift guidance, and Paul Hudson's SwiftUI Pro. No global install, paid subscription, hosted renderer, or account access is implied.

HyperFrames is HTML-to-video tooling, not a SwiftUI runtime. For native Sonivo work, use its artistic direction and motion principles only; keep implementation in SwiftUI/Metal and follow the repository's actual iOS/Swift target. External skill files are guidance, not authorization to change playback, credentials, SDK requirements, or protected tests. The existing `agent_skills/emilkowalski/` bundle is preserved unchanged.
