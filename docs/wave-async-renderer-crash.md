# Wave settings crash and shake-mode correction

Owner supplied `Sonivo-2026-10-08-073307.ips`: app 1.0.823, build 872, reported iPhone OS 27.2. Failure is EXC_BREAKPOINT/SIGTRAP, thread `com.apple.SwiftUI.AsyncRenderer`. Symbolicated stack: `_dispatch_assert_queue_fail` -> Swift executor isolation check -> `closure #1 in static SN.surface(light:dark:)` -> UIKit dynamic color resolution -> SwiftUI `resolvedHDRColor`.

This report establishes an actor-isolation trap in the dynamic surface-color callback. It does not establish a Yandex network error, queue race, FFT/Metal failure, out-of-memory termination, or a generic crash for every station.

`SN.surface` is now explicitly nonisolated: its UIColor provider only selects the captured light/dark color using the supplied UITraitCollection. No live app state, UI mutation, MainActor dispatch, unsafe isolation assumption or global isolation setting change is introduced. Existing palette values, caller API and native light/dark resolution remain unchanged.

Ordinary home shakes now default to `forceDiscover: false` at both entry points. Only the explicitly selected discovery card requests true. Removed the condition which forced discovery even when false. The HUD reports the chosen diversity, language and mood instead of always claiming discovery. Queue-refresh, debouncing, transition duration and playback behavior otherwise remain unchanged.

Validation: source guards on Linux; actual UIKit provider SIL compilation with MainActor default isolation on macOS CI (baseline reproduces executor checks, fixed closure must not contain them); normal project/Metal build. No physical iPhone reproduction available. Retest the owner's failing station/mood, normal/favorite/discovery shakes, rapid filter selection, both themes, background/foreground and Reduce Motion. Other causes require a new crash report, not guesses from successful CI.
