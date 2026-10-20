# Sonivo · typographic lyrics

Approved direction: oversized left-aligned type on charcoal with a restrained user-accent glow, a quiet surrounding lyric context, and an immediate Typography / Lines selector. This is native SwiftUI, not an embedded video or a replacement playback engine.

## Surfaces and preferences
- Full-screen player, lyrics sheet and cover share TypographyLyricsView.
- The full lyric player keeps its actual transport/timeline visible in typography mode, with smaller cover metadata and an explicit return-to-player button. The standard player and its artwork background are unchanged.
- Typography is the default only when no recognized design is saved. Existing classic/staggered selections and custom lyrics, font size, timing offset and source caches remain intact.
- The segmented control persists the same settings key as Settings → Lyrics. Aa changes the existing size setting; all existing designs remain available in Settings.
- No made-up translation, lossless badge, artist, song title or lyric is added to production. The approved mockup used illustrative content.

## Timing and interaction
- Real playback time uses LyricsPlaybackClock, including the existing streaming-vs-render-latency policy and manual offset.
- Only validated, text-matching provider word timestamps may color individual words. Missing/mismatched/invalid words fall back to whole-line emphasis, never estimated per-word timing.
- Explicit line ends stop emphasis in instrumental gaps. Plain lyrics remain scrollable, readable and untimed.
- Tapping a synchronized lyric seeks through the existing player router; a paused song stays paused.
- Manual scrolling suspends auto-follow; “К текущей” resumes immediately, otherwise follow resumes five seconds after the drag ends. Tasks cancel on disappearance/background.
- Native shaping retains punctuation, whitespace and Unicode. Text wraps, scales with Dynamic Type, supports VoiceOver and Increased Contrast, and disables movement with Reduce Motion.
- No independent display-link or 120Hz loop, source network request, transcription, audio session or queue modification is introduced.

## Validation
`python3 .github/scripts/run_ci_tests.py` includes integration guards and a macOS Swift executable fixture for true timing boundaries, gaps, zero-time starts, plain text, invalid/mismatched words and Unicode preservation. Xcode CI validates actual SwiftUI compilation. Device QA remains necessary for visual spacing at accessibility sizes, long RTL/CJK lyrics, manual scrolling, seeks, pause, track changes and multiple accent colors.
