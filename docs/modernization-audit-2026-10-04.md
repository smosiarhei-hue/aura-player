# Sonivo modernization audit

Date: 2026-10-04  
Branch: `feature/modern-my-wave-home`  
Scope: SwiftUI app, audio packages, tests, CI, scripts, repository hygiene, accessibility, localization, and motion.

## Executive summary

The project has a strong product direction, a real design system, strict Swift 6 concurrency enabled, a meaningful audio-engine test suite, and a polished My Wave concept. It is not ready to call “fully clean” yet. The largest risks are exposed credentials, oversized and tightly coupled source files, security-sensitive data stored in `UserDefaults`, incomplete localization/accessibility coverage, and repository bloat.

The first security remediation is included on this branch:

- remove embedded NVIDIA, Dify, and Yandex credentials from current source;
- migrate AI and Yandex credentials from `UserDefaults` to Keychain;
- require explicit user authorization instead of shipping a shared Yandex token.

The credentials previously committed must still be revoked and rotated. Removing them from the latest tree does not remove them from Git history.

## Validation boundary

- Audited 131 Swift files and approximately 35,989 lines.
- Inspected XcodeGen configuration, four GitHub Actions workflows, Python tooling, assets, tests, and bundled web tooling.
- Python scripts compile successfully.
- iOS build and tests were not run locally because this Linux environment has no Xcode/Swift toolchain. The branch CI is the authoritative compile/test gate.
- GitHub Advanced Security secret scanning is not enabled for this repository, so credential review was performed locally.

## What is already solid

- `SWIFT_VERSION: 6.0` and complete strict concurrency are enabled.
- The branch CI runs for `feature/modern-my-wave-home`.
- The unit-test target contains 18 files and 72 test functions, with useful coverage around AutoMix, streaming, retry limits, beat matching, and audio sessions.
- The main My Wave background pauses reactive rendering for Reduce Motion and inactive scene phases.
- The mini-player uses scaled metrics, 44-point controls, clear accessibility labels, and native SwiftUI transitions.
- Design constants and reusable components exist instead of every screen inventing a separate visual language.

## Findings

### P0 — security

#### 1. Credentials were committed in source

Affected areas:

- `Sonivo/Dify/DifyService.swift`
- `Sonivo/yandexmusicservice.swift`

Risk:

- anyone with repository/history access can reuse the credentials;
- deleting literals in a later commit does not invalidate or erase them.

Remediation:

- implemented current-tree removal and Keychain migration on this branch;
- revoke and rotate all affected credentials immediately;
- purge sensitive blobs from Git history if the repository’s exposure model requires it;
- add secret scanning in CI (for example, Gitleaks) because GitHub Advanced Security scanning is unavailable.

#### 2. Tokens were persisted in `UserDefaults`

AI provider keys and the Yandex token were stored as plain preferences. `UserDefaults` is appropriate for non-sensitive settings, not credentials.

Remediation:

- implemented `SecureCredentialStore` backed by Keychain;
- migrate legacy values once, then remove them from `UserDefaults`;
- keep provider choice, endpoint, and model name in `UserDefaults`.

### P1 — correctness and maintainability

#### 3. Core files are too large

There are 22 Swift files over 500 lines and six over 1,000 lines. The largest include:

- `Sonivo/playercore.swift`
- `Sonivo/yandexmusicservice.swift`
- `Sonivo/PlayerScreenV2.swift`
- `Sonivo/VideoShot/AIVideoShotGeneratorService.swift`
- `Sonivo/artistviews.swift`
- `Sonivo/Dify/AIMusicAssistantView.swift`

Risk:

- broad actor isolation and state ownership become difficult to reason about;
- changes create large regression surfaces;
- views recompute more than necessary;
- tests must reach through singleton-heavy implementations.

Target structure:

- split transport, queue, streaming, audio-session, equalizer, and remote-command responsibilities out of `PlayerCore`;
- split authentication, API client, caching, catalog mapping, and playback URL resolution out of `YandexMusicService`;
- split full-screen player sections into small views with explicit input state and actions;
- inject protocols into feature stores instead of reading every dependency from `.shared`.

#### 4. Concurrency escape hatches need proof

Observed:

- 14 `@unchecked Sendable` declarations;
- three `nonisolated(unsafe)` uses;
- six `Task.detached` uses.

These may be valid around AVFoundation/DSP boundaries, but every occurrence should document:

- who owns the mutable state;
- which executor/queue may access it;
- why checked isolation cannot express the invariant;
- how cancellation and lifetime are handled.

Prioritize audio callbacks, playback coordination, and analysis tasks. Replace `Task.detached` with structured tasks unless executor independence is required and measured.

#### 5. UI behavior has no UI-test target

The unit suite is valuable but does not validate:

- My Wave gestures and settings;
- player presentation/dismissal;
- Dynamic Type layout;
- Reduce Motion behavior;
- authentication flows;
- offline/loading/error states.

Add a small UI smoke suite before large visual refactors.

#### 6. Dead and placeholder paths remain

Examples:

- `MyWaveHeroView` contains an intentionally unreachable `if let ..., false` block;
- vocal-isolation code contains TODO placeholders for actual Core ML inference;
- legacy and V2 playback paths remain interleaved.

Delete unreachable retention tricks, clearly feature-flag incomplete functionality, and document the migration boundary between legacy and V2 playback.

### P1 — product design and accessibility

#### 7. Dynamic Type support is inconsistent

The codebase contains many fixed frames and fixed-size fonts:

- 165 `.frame(width:)` occurrences;
- 187 `.font(.system(size:))` occurrences;
- only one explicit `dynamicTypeSize` policy.

Not every fixed dimension is wrong (artwork and icons often need one), but text containers, header controls, chips, and cards need stress testing at accessibility sizes.

My Wave has two 40×40 header controls. Raise interactive hit regions to at least 44×44 while preserving the visible 40-point circles if desired.

#### 8. Localization coverage is effectively absent

`Sonivo/Localizable.xcstrings` contains one localized key while the UI has many inline Russian strings.

Move user-facing text into the string catalog, including:

- tab labels;
- loading/error/status messages;
- settings and authentication;
- accessibility labels and hints;
- pluralized counts and durations.

Keep internal API/model identifiers out of localization.

#### 9. Accessibility metadata is uneven

Observed:

- 47 accessibility labels;
- one accessibility hint;
- ten Reduce Motion references.

Decorative visuals are often hidden correctly, but complex gestures and stateful controls need:

- values for progress, sliders, EQ, and playback state;
- hints for non-obvious swipe/shake interactions;
- rotor/order checks on the full player;
- VoiceOver alternatives for drag-only controls.

#### 10. Motion needs consolidation

Observed:

- 69 `withAnimation` calls;
- 35 `.animation` modifiers;
- several UI transitions over 300 ms;
- multiple long-running ambient animations.

The My Wave implementation has good Reduce Motion foundations. Remaining work:

- use shared motion tokens rather than one-off spring/easing values;
- keep frequent control feedback short;
- reserve long loops for ambient, non-interactive decoration;
- verify that repeated animations stop when playback or scene activity stops;
- keep gesture-driven state interruptible and tied to the finger;
- test on a physical 120 Hz device with Energy Log.

See `plans/001-my-wave-motion-accessibility.md`.

### P2 — repository and delivery hygiene

#### 11. Large generated/binary artifacts are tracked

Tracked items include:

- multiple large MP4 files;
- a root `output.mp4`;
- `ios-automix-dsp-implementation.zip` despite `*.zip` being ignored;
- generated Python bytecode in repository history;
- a one-byte `incoming` file.

Two bundled MP4 files are byte-for-byte identical but both are referenced as fallbacks. Consolidate the resource and update the lookup code before deleting either path.

Move generated output to CI artifacts/releases or Git LFS. Keep only runtime assets required by the app bundle.

#### 12. CI should enforce repository policy

Add fast checks before the macOS build:

- secret scan;
- reject tracked `__pycache__`, `.pyc`, ad-hoc ZIP, and root output files;
- validate `project.yml`;
- run Python tests;
- optionally run SwiftFormat/SwiftLint with a pinned version and a small, intentional rule set.

Do not make formatting changes across the whole repository in the same PR as behavior changes.

## Recommended execution order

1. Revoke exposed credentials and merge the Keychain/current-tree cleanup.
2. Add secret and repository-hygiene CI checks.
3. Run branch CI and fix any Swift 6/Xcode failures.
4. Add My Wave UI smoke tests and accessibility checks.
5. Execute the My Wave motion/accessibility plan.
6. Extract `YandexMusicService` responsibilities.
7. Extract `PlayerCore` responsibilities.
8. Expand localization and Dynamic Type coverage screen by screen.
9. Remove or move generated/binary artifacts.

## Definition of done

- no credential literals or sensitive values in preferences;
- all affected credentials rotated;
- branch build and unit tests green;
- My Wave passes VoiceOver, Reduce Motion, Dynamic Type, and interruption checks;
- no essential control has a hit region below 44×44;
- user-facing strings are cataloged;
- concurrency escape hatches are documented and tested;
- generated artifacts are not committed;
- core services have focused responsibilities and injectable dependencies.