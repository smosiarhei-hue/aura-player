> EQ UI and frequency layout superseded by [compact curve EQ](compact-curve-eq.md). Historical implementation notes below.

# Stronger bass and queue continuation

Historical ten-band stage. The current dense bass layout and compact controls supersede the EQ-layout details below; see `dense-bass-eq.md`. Radio continuation remains unchanged.

## EQ and native UI
- Ten original frequency centers remain 30, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 20000 Hz.
- First three low-frequency controls allow -12…+18 dB; other bands remain -12…+12. Shared Swift gain limits cover normalization, native AU writes, preset validation and UI. Portable PCM DSP applies the same per-band bounds.
- New explicit factory preset “Мощный саббас”: [14, 10, 5, -2, -1, 0, 0, 0, 0, 0]. Existing factory/personal curves are not automatically overwritten. Saving/reloading high-bass custom presets is supported.
- Vertical slider travel increased 180→260 points. Native controls and VoiceOver/large-text row fallback remain. Positive endpoint labels reflect each band's actual range.
- Unity preamp, output limiter policy, headphone routing, iOS system volume/security limits and EQ-off/flat bypass are unchanged. More gain may cause clipping/distortion or excessive loudness. UI warns to increase gradually at moderate volume. This does not guarantee a physical vibration sensation, hardware capability, HDR audio or iPhone listening quality.

## Continuation
- Prepare a catalog track station during the **last track of a finite playlist**, not five tracks earlier. Existing active stations prefetch when five or fewer tracks remain. Explicit finite repeat-one/repeat-all behavior is retained; inactive repeat modes do not start a station in advance.
- Prefetch, automatic end and manual Next share one loader owned by queue lifetime + account identity. A normal internal song advance does not discard a still-valid active-session batch simply because the transient song-generation changed. Explicit play/pause/stop/replacement invalidates old work.
- End/Next recheck queued tracks after awaiting: if prefetch already appended the same batch, play that queued continuation rather than interpreting “no fresh items” as end of music.
- Loader retries empty/transient results at most three times with 1s/2s delays, no parallel station start. Wave request timeout is 20s per HTTP request, not a whole-operation guarantee (feedback/session setup may involve multiple requests).
- Catalog track radio uses existing Yandex server sessions, ordered server batches, duplicate checks, playback feedback and expired-session renewal. No AI/chart/local reranking is added for server radio. Legacy explicitly selected local mood-radio behavior remains separate.
- Manual Next at the end of a signed-in catalog queue now requests continuation rather than wrapping to the first playlist song. Failed finished-item resume requests continuation again instead of calling play on an ended AVPlayerItem.
- Online catalog sessions can keep fetching subsequent batches without a fixed track count. No promise of infinite playback while offline, with an expired login, unavailable tracks or an exhausted server response. After bounded failure show an error/retry action. Local files without a catalog ID cannot seed Yandex radio; use explicit playlist repeat for local-only continuous listening.

## Verification
- Actual C PCM DSP tests measure stronger low-frequency response above the old +12 cap, unchanged midrange/unity preamp, unchanged high-band ceiling and finite output. They are not listening tests on a device.
- Native Swift preset fixture tests save/reload +18 low-band curves, reject +18.5 and high-band +12.5, preserve old valid archives and do not overwrite broken archives.
- Native Foundation executable tests the actual continuation loader for shared single-flight, empty-result retry, retry exhaustion and cancellation/stale results. Structural player guards verify queue/account ownership, both post-await rechecks, native session ordering and last-song prefetch.
- Existing real Yandex-session fixtures remain; no live user music-token test or locked-iPhone playback test was run here. Verify full playlist→radio and network interruption on device.
