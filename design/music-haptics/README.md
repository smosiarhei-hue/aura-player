# Audio-owned haptics and grouped icon styles

Music haptics consume the actual PCM feature frames independently of Metal views.
Streaming frames use AVPlayer media time; local captures use audio host time and
AVAudioSession output latency. The bounded causal queue never fires a future frame;
frames older than 80 ms are discarded instead of generating a catch-up burst.
Confirmed kick IDs are consumed once. No synthesized BPM fallback.

Modes: Beat (default) plays only confirmed kick pulses, with a crisp transient and
65 ms body. Full follows all audible PCM continuously, including non-bass passages;
measured spectrum and treble attacks vary sharpness. Sustained vibration pauses
for 85 ms around a kick so two patterns do not stack into an unintended strength.

Apple documents CHHapticEvent.ParameterID.hapticIntensity as 0.0...1.0:
https://developer.apple.com/documentation/corehaptics/chhapticevent/parameterid/hapticintensity
Sharpness also ranges 0.0...1.0 (crispness, not extra motor amplitude):
https://developer.apple.com/documentation/corehaptics/chhapticevent/parameterid/hapticsharpness
Soft/Medium/Strong use normalized ceilings 0.35 / 0.70 / 1.00. The confirmed kick
is no longer attenuated a second time by detector confidence. Full-mode strength
is no longer capped at 0.45 or multiplied again by quiet spectral bands.
Automatic loudness uses bounded perceptual compression; loud frames can reach 1.0,
quiet PCM remains lower, and silence stays off. Turning automatic adaptation off
uses the exact selected ceiling. Preview exercises that same ceiling, not 45% of it.
API maximum is not a measured physical force and cannot overdrive Apple's hardware.

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
