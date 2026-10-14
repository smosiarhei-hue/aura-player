# Audio-owned haptics and grouped icon styles

Music haptics consume the actual PCM feature frames independently of Metal views.
Streaming frames use AVPlayer media time; local captures use audio host time and
AVAudioSession output latency. The bounded causal queue never fires a future frame;
frames older than 80 ms are discarded instead of generating a catch-up burst.
Confirmed kick IDs are consumed once. Treble attacks and the continuous bass
intensity are derived from measured PCM features. No synthesized BPM fallback.

Automatic strength is enabled by default; the existing Soft/Medium/Strong preference
sets its ceiling. It is not a calibration of physical actuator force. Silence is gated,
pauses/seeks invalidate queued commands, and a separate hardware-queue watchdog
stops continuous vibration within 200 ms of the last received command even if the
main actor stalls. Background playback deliberately has no music haptics.

Limitations: unavailable/protected PCM streams cannot drive this feature. Bluetooth,
route latency estimates, OS interruptions and different actuators affect alignment.
No 99% accuracy, Apple Music parity or accessibility certification is claimed.
A passing Swift fixture or CI build does not measure vibration on a real iPhone.
Device acceptance: verify speaker/AirPods, soft passage vs loud beat, silence,
pause, seeking, app background, shader launch exclusion and each strength ceiling.

The single icon selection page groups Matte, Graphite, Prism, Ice Chrome and Neon
under S + Sound. Signature S, Wordmark and Classic Wave remain separate choices.
All five music styles share the exact approved original three foreground paths.
Materials use native Icon Composer layers; simple color gradients are SVG paint,
not baked specular reflections, shadows or rounded masks. Settings show flat
thumbnails. Native rendering is validated by the existing macOS Actions workflow.
The toolchain is the available Apple SDK, not a promise of an iOS 27 SDK.
