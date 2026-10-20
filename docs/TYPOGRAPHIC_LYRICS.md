# Sonivo · typographic lyrics

Approved direction: oversized left-aligned type on charcoal with a restrained user-accent glow, a quiet surrounding lyric context, and an immediate Typography / Lines selector. This is native SwiftUI, not an embedded video or a replacement playback engine.

## Surfaces and preferences
- Full-screen player, lyrics sheet and cover share TypographyLyricsView.
- The full lyric player initially reveals its transport/timeline, with smaller cover metadata and an explicit return-to-player button. After 10 idle seconds it can collapse, leaving a persistent “Показать управление” button. Touching or dragging the panel cancels the deadline and starts a fresh 10-second idle period after release. Paused, buffering, inactive or VoiceOver states never auto-hide. The standard player and its artwork background are unchanged.
- Typography is the default only when no recognized design is saved. Existing classic/staggered selections and custom lyrics, font size, timing offset and source caches remain intact.
- The segmented control persists the same settings key as Settings → Lyrics. Aa changes the existing size setting; all existing designs remain available in Settings.
- No made-up translation, lossless badge, artist, song title or lyric is added to production. The approved mockup used illustrative content.

## Timing and interaction
- Real playback time uses LyricsPlaybackClock, including the existing streaming-vs-render-latency policy and manual offset. Streaming samples AVPlayer.currentTime() directly; native-file playback reads the existing live playback anchor. A generation/track/request-checked pending seek target prevents stale pre-seek time. An unready/empty stream or inactive native node never supplies a previous track’s time.
- Only validated, text-matching provider word timestamps may color individual words. Missing/mismatched/invalid words fall back to whole-line emphasis, never estimated per-word timing.
- All line-based surfaces share TypographyLyricsPolicy.activeIndex. Selection remains on the current row until the next source start, matching Lines; explicit word ends bound the word sweep rather than prematurely clearing scroll focus. Plain lyrics remain readable and untimed. Classic dynamic phrases also retain selection until the next source start and no longer add a fabricated 25 ms prediction.
- Tapping a synchronized lyric seeks through the existing player router; a paused song stays paused.
- Manual scrolling suspends auto-follow; “К текущей” resumes immediately, otherwise follow resumes five seconds after the drag ends. Tasks cancel on disappearance/background.
- Native shaping retains punctuation, whitespace and Unicode. Text wraps, scales with Dynamic Type, supports VoiceOver and Increased Contrast, and disables movement with Reduce Motion.
- One view-scoped CADisplayLink in common run-loop mode requests the actual window screen’s maximum, up to 120 Hz. It samples, but never extrapolates or advances, audio time. Only the current timed-word row observes frameTime; list selection changes only at a line boundary. The renderer clips a continuous sweep through the provider’s word interval instead of switching an entire word at its start.
- The display link invalidates on pause, buffering, inactive scene, Reduce Motion, detachment and dismantling. Low Power / serious thermal cap at 30 Hz, critical thermal at 15 Hz. Reduced-motion lyrics still receive actual source time from audio progress updates. Apple/iOS retains final refresh-rate control; 120 Hz is a request, not a measured guarantee.
- No source network request, transcription, audio-session activation, queue or EQ modification is introduced.

## Validation
`python3 .github/scripts/run_ci_tests.py` includes integration guards and a macOS Swift executable fixture for true timing boundaries, gaps, zero-time starts, plain text, invalid/mismatched words and Unicode preservation. Xcode CI validates actual SwiftUI compilation. Device QA remains necessary for visual spacing at accessibility sizes, long RTL/CJK lyrics, manual scrolling, seeks, pause, track changes and multiple accent colors.

## Apple references
- https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange
- https://developer.apple.com/documentation/avfoundation/avplayer/currenttime()

Frame-rate and clock guards plus the executed Swift fixture cover selection boundaries, offsets via the existing clock, gap focus parity, exact text matching, and all pause/buffering/visibility/VoiceOver auto-hide combinations. Physical-device validation of frame cadence and source-provider vocal accuracy is still required.
