# Compact curve EQ — 30 Hz to 15 kHz

Supersedes the dense 29-band UI at the user's request. One fixed-width graph shows all real controls: **30, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 15000 Hz**. There is no horizontal EQ scroll view.

- Smooth connecting curve and ten draggable nodes, with the selected band locked for the gesture. The connecting curve displays control gains, not a measured summed filter response.
- Ten frequency selection buttons in two rows of five, at least 44 points tall, plus a native adjustable horizontal slider for exact 0.5 dB edits to the selected band. No need to drag tightly packed graph nodes. VoiceOver labels include frequency and gain.
- Large accessibility text uses ten vertical native slider rows; scrolling stays vertical only. Light/dark themes use existing semantic colors. Graph precedes preset profiles.
- 30 Hz low shelf / 15 kHz high shelf; intervening filters one octave wide. All three playback EQ paths agree on centers, counts, widths and bounds. Low controls through 250 Hz allow −12…+18 dB; others −12…+12 dB. Unity preamp and the existing user-requested absence of an app peak limiter are unchanged. System volume is untouched.
- Previous dense 29-value and historical 10-value curves are interpolated in log-frequency to these centers, with one-time original-data backups. `eq.layout.compact10` makes main-curve migration idempotent. Saved presets now include their frequency table, so new ten-value curves cannot be misidentified as old ten-value curves. UUIDs/names/order survive. Corrupt or unknown preset metadata is not overwritten. Changing filter centers/widths does not guarantee identical acoustic response to the previous layout.

Validation: portable actual C DSP tests (center gain, limits, sample rates, channel isolation, high-level behavior and smooth changes); native Swift fixtures for save/reload/delete/corruption, both migrations, metadata and relaunch idempotence; actual shared graph geometry checks at widths 216–568 points and gain/position round trips. Native Swift fixtures and iOS compilation run on macOS CI. No headphone listening or device drag test is claimed from CI.
