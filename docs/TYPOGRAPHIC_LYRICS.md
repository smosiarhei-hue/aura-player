# Sonivo · typographic lyrics

Approved direction: oversized left-aligned type on charcoal with a restrained user-accent glow, a quiet surrounding lyric context, and an immediate Typography / Lines selector. This is native SwiftUI, not an embedded video or a replacement playback engine.

## Surfaces and preferences
- Full-screen player, lyrics sheet and cover share TypographyLyricsView.
- The full lyric player initially reveals its transport/timeline, with smaller cover metadata and an explicit “Закрыть текст” action in the lower controls. The top chevron only collapses the whole player. After 10 idle seconds it can collapse, leaving persistent “Показать управление” and “Закрыть текст” actions. Touching or dragging the panel cancels the deadline and starts a fresh 10-second idle period after release. Paused, buffering, inactive or VoiceOver states never auto-hide. The standard player and its artwork background are unchanged.
- Typography is the default only when no recognized design is saved. Existing classic/staggered selections and custom lyrics, font size and source caches remain intact. Legacy manual calibration is removed on startup; there is no timing slider or hidden calibration menu.
- The segmented control persists the same settings key as Settings → Lyrics. Aa changes the existing size setting; all existing designs remain available in Settings.
- No made-up translation, lossless badge, artist, song title or lyric is added to production. The approved mockup used illustrative content.

## Timing and interaction
- Real playback time uses LyricsPlaybackClock, without manual shift, route-latency subtraction, wall-clock lookahead or entrance delay. Source-defined LRC offset metadata is still parsed normally; this is not a user calibration. Streaming samples AVPlayer.currentTime() directly; native-file playback reads AVAudioPlayerNode.playerTime(forNodeTime:) plus the scheduled segment’s source-frame offset. It does not use Date-based elapsed time. Segment-token matching prevents a previous node/seek from supplying stale time. A generation/track/request-checked pending seek target prevents stale pre-seek time. An unready/empty stream or inactive native node never supplies a previous track’s time.
- Only validated, text-matching provider word timestamps may color individual words. Missing/mismatched/invalid words fall back to whole-line emphasis, never estimated per-word timing.
- All line-based surfaces share TypographyLyricsPolicy.activeIndex. Selection remains on the current row until the next source start, matching Lines; word ends do not prematurely clear scroll focus. Plain lyrics remain readable and untimed. Classic dynamic phrases also retain selection until the next source start and no longer add a fabricated 25 ms prediction.
- Tapping a synchronized lyric seeks through the existing player router; a paused song stays paused.
- Manual scrolling suspends auto-follow; “К текущей” resumes immediately, otherwise follow resumes five seconds after the drag ends. Tasks cancel on disappearance/background.
- Native shaping retains punctuation, whitespace and Unicode. Text wraps, scales with Dynamic Type, supports VoiceOver and Increased Contrast, and disables movement with Reduce Motion.
- All scrolling designs share LyricsClockSurface and a view-scoped CADisplayLink in common run-loop mode requests the actual window screen’s maximum, up to 120 Hz. It samples, but never extrapolates or advances, audio time. Only the current timed-word row observes frameTime; list selection changes only at a line boundary. Each real timed word becomes fully emphasized exactly at its source start, without fade-in, blur, rise, sweep completion or implicit animation. The same immediate onset is used by Classic dynamic and synchronized Staggered renderers; decorative stagger is confined to untimed previews.
- Automatic focus uses a shared 240 ms zero-bounce smooth viewport transition. Selection/word onset updates immediately and word leaves suppress implicit animation, so motion does not shift timestamps. Reduce Motion scrolls immediately; cover-row emphasis has no opacity animation. Manual “К текущей”/tap navigation may still animate independently of highlighting.
- The display link invalidates on pause, buffering, inactive scene, Reduce Motion, detachment and dismantling. Low Power / serious thermal cap at 30 Hz, critical thermal at 15 Hz. Reduced-motion lyrics still receive actual source time from audio progress updates. Apple/iOS retains final refresh-rate control; 120 Hz is a request, not a measured guarantee.
- No source network request, transcription, audio-session activation, queue or EQ modification is introduced.

## Validation
`python3 .github/scripts/run_ci_tests.py` includes integration guards and a macOS Swift executable fixture for true timing boundaries, gaps, zero-time starts, plain text, invalid/mismatched words and Unicode preservation. Xcode CI validates actual SwiftUI compilation. Device QA remains necessary for visual spacing at accessibility sizes, long RTL/CJK lyrics, manual scrolling, seeks, pause, track changes and multiple accent colors.

## Apple references
- https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange
- https://developer.apple.com/documentation/avfoundation/avplayer/currenttime()

Frame-rate and clock guards plus the executed Swift fixture cover selection boundaries, zero-shift clock behavior and exact word onsets, gap focus parity, exact text matching, and all pause/buffering/visibility/VoiceOver auto-hide combinations. Physical-device validation of frame cadence and source-provider vocal accuracy is still required.

## Full pipeline audit
- Yandex now requests `/tracks/{id}/lyrics?format=LRC&timeStamp=…&sign=…`, then downloads the returned HTTPS `downloadUrl` without forwarding OAuth. The supplement remains a fallback. API contract checked against the upstream implementation below; availability still depends on account/track rights.
- After explicit user custom lyrics, catalog-ID synchronized text has priority over title-matched third-party timing. Existing title/artist/duration checks are retained for fallback providers; no stretching or guessed offset is introduced.
- Enhanced LRC syllables merge into displayed words using the first actual syllable timestamp; terminal tags retain their end boundary. Repeated line tags relocate the same source word timestamps to each occurrence. Original punctuation, Unicode, source offsets (once only), and plain fallback remain intact.
- Only active timed-word rows observe frameTime. Scrolling line lists no longer use queued periodic progress callbacks to select rows. The whole player no longer samples playback time unconditionally when rendering Typography.
- Local LYRICS diagnostics record chosen source, source offsets, line/first-word boundaries and long (>150 ms, rate-limited) display-frame gaps. They contain no lyric body, OAuth token, key or signed URL. A boundary record is not a measurement of audible vocal accuracy.
- No EQ, playback ownership, queue, audio-session activation, icon, launch, signing or music-haptics behavior is changed. Hardware/display cadence and provider vocal alignment still require a device test with the specific recording.

### Upstream/API references
- https://github.com/MarshalX/yandex-music-api/blob/main/yandex_music/_client/tracks.py (`tracks_lyrics`)
- https://github.com/MarshalX/yandex-music-api/blob/main/yandex_music/utils/sign_request.py (`get_sign_request`)
- https://github.com/MarshalX/yandex-music-api/blob/main/yandex_music/track/track_lyrics.py (`download_url`, `fetch_lyrics`)
- https://developer.apple.com/documentation/avfaudio/avaudioplayernode/playertime(fornodetime:)

CI executes additional real Swift fixtures for LRC units/offset signs, syllables, leading words, repeated tags, malformed timestamps, Unicode, 44.1/48/96 kHz native sample positions and a fixed upstream-compatible HMAC signature.

## Typography / luminous text study
- Active typographic words use a crisp white fill with one restrained accent-colored halo; future words remain dim. Increased Contrast disables the halo. This is an SDR HDR-style treatment, **not** actual EDR/HDR luminance output.
- Source clocks, parsers and provider offsets are unchanged by this visual pass. No fade-in or delayed transaction is added to word highlighting.
- Candidate fonts are preview-only: Inter Tight, Manrope, Onest, Golos Text, Montserrat and Rubik (Google Fonts, SIL OFL). No font family is bundled/selected in production before user approval.
