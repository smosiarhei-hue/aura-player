# Library responsiveness after account synchronization

## Confirmed code costs
- Eager track VStack instantiated every song row/artwork/context menu after imports.
- Each row/Now Playing favorite check linearly searched the full library, multiplying list rendering cost.
- Favorite cloud merge searched the growing array for every incoming item (quadratic).
- Every track/playlist mutation JSON-encoded and atomically wrote the entire index on MainActor, with redundant explicit writes on top of didSet.
- Guest file existence, search and sorting ran during view/body evaluation; playlist rows repeatedly rebuilt the library lookup dictionary.
- Large cloud playlist JSON decode and metadata conversion ran on MainActor; independent account refresh callers could overlap.
- Local file-picker copies/NSFileCoordinator operations ran synchronously on MainActor.

## Changes
- Lazy vertical track stacks and horizontal playlist shelves.
- Cancellable background projections: file checks, filter, search and sort run against a value snapshot. Track revision/login/filter/query keys reject stale completions; guest UI immediately excludes an old signed-in projection. Search debounce is 150 ms, not a delay in track playback.
- Playlist detail resolves tracks once per library/playlist/login revision rather than per row.
- Indexed first-ID/first-filename lookup preserves legacy first-match semantics; favorites refresh invalidates the index through a revision. Cloud favorite merge is linear and suppresses duplicate incoming IDs.
- One utility writer JSON-encodes/writes metadata away from UI. Latest pending snapshot per index file replaces older pending work; 120 ms coalescing bounds redundant writes. Atomic file writes remain; reset/deletion uses the same serial writer, so an old job cannot overwrite a completed reset. A write already in flight finishes before the latest queued state.
- Loading the existing index does not rewrite it. Background transition requests a flush with a system background-task lease. Persistence errors are retained in writer diagnostics, not silently treated as success.
- Single account-generation-owned synchronization task; logout/account reset cancels it. Network/session validation and limits (50 playlists, 2000 entries) remain unchanged. Playlist JSON decode and pure track conversion run off MainActor; account/cancellation checks still gate final commits.
- Security-scoped local file copies run on a background task while access remains held. No additional dependencies, track downloads, or PCM storage.

## Deliberately unchanged
- Seek tolerance, decoder buffering, audio capture/EQ, detector/Beat Waves physics, stream wave ordering and playback algorithms.
- Existing first index read/decode on initial LibraryStore construction remains synchronous. This is a possible startup cost for unusually large stored indexes; changing bootstrap requires a separate transactional loading/mutation design rather than silently overwriting user/account changes.
- Existing image cache behavior and actual network/AVPlayer delay are not claimed as measured/fixed by these metadata/list optimizations.

## Checks
- Structural tests for lazy containers, background revision-owned projection, indexed favorites, serial background writer, reset/flush, cached playlist resolution, single-flight sync and scoped copy.
- macOS executable: 10,000-track lookup/filter parity, filename/ID collisions, guest missing/remote-file filtering, cancellation; 1000 pending snapshots coalesce to one final version per file; encoder is off main; asynchronous flush and delete/write ordering are exercised.
- Fixture timing measures indexed metadata lookup only, not iPhone frame rate or network track startup.
- On the owner's iPhone: open a synced large collection, scroll/search/favorite while music plays, switch playlists/tracks, seek inside buffered and unbuffered audio, background/relaunch and verify saved favorites/playlists. Note whether delay is UI response or waiting for audio/data. Instruments Time Profiler/Hangs can identify remaining disk/image/network costs.
