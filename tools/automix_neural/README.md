# AutoMix beat-model research (offline, not shipped)

This is a reproducible CPU experiment for **Beat This! small0**, not part of iOS playback, not a calibrated confidence score and not a new AutoMix runtime. It produces candidate beat/downbeat timestamps and synthetic metrics only. The existing app is unchanged; never use these outputs for transition, rate, loop, or FX decisions without further validation.

## Reproduce

Requires Python with `numpy`, `onnxruntime`, and optionally `ffmpeg` for a local audio file. The files below are an independently exported pair from [beat-this-rs](https://github.com/danigb/beat-this-rs) at commit `1ae768e78f1ad83b0ed3886241dc29ffde853c40`. Original research and model authors: [Beat This!](https://github.com/CPJKU/beat_this). Code and published weights are MIT, but the authors caution about rights to some training data; assess suitability before distribution. The two files are not bundled with Sonivo. Reference-port copyright and license are in `LICENSE-beat-this.txt`.

Download both `models/mel_spectrogram.onnx` and `models/beat_this_small.onnx` from that exact commit into a local directory. The benchmark verifies pinned SHA-256 digests before loading. Then:

```sh
python3 tools/automix_neural/benchmark.py --model-dir /path/to/models
AUTOMIX_BEAT_MODEL_DIR=/path/to/models python3 -m unittest discover -s tools/automix_neural -p 'test_*.py'
# Optional: local data stays local; first 25 seconds only. No reference accuracy is computed.
python3 tools/automix_neural/benchmark.py --model-dir /path/to/models --audio /path/to/audio
```

CPU session uses two threads; audio is 22,050 Hz mono, output resolution 50 frames/second. The experiment follows the port's six-frame border and logit > 0 peak convention for a short single chunk; does not implement long-track stitching. It does not guarantee parity with the original inference pipeline or any conversion to Core ML. The WAV decoding/resampling path is ffmpeg, not the app's AVAudioConverter. Timing excludes model loading and is **not** iPhone performance.

## Initial synthetic observation

On one 12-second artificial kick sequence at nominal 120 BPM, this CPU run matched 24/24 beats within 70 ms, but produced 24 downbeat events against six artificially labelled bar starts (18 false positives). On a separate synthetic gradual tempo drift it matched 21/22 beats and 5/6 downbeats, with 13 extra downbeat events. Silence produced no events. These are only three generated signals; a synthetic bar accent is not a musically authoritative downbeat. Results do not establish model accuracy on actual music, generalization, iPhone performance, or threshold calibration.

## Work before shipping

1. Validate provenance/export and compare frontend, chunk borders and post-processing against original reference across a held-out, licensed, human-annotated music corpus (including downbeat, syncopation, live/drift, intros and silence). Measure error, precision/recall and failure categories, especially false-safe downbeats, not only BPM.
2. Establish calibrated local-window reliability, ambiguous/unknown outcomes and independently checked cue timing. Don't infer downbeat confidence from BPM or use logits as calibrated probability. Preserve fallback for poor or absent evidence.
3. Convert and validate Core ML on supported iOS versions; compare per-frame outputs to reference within a justified tolerance, and measure latency, memory, battery, startup and background cancellation on real iPhones. No ONNX runtime is included in the app.
4. Integrate asynchronously with versioned/fingerprinted cache and pair/generation guards; only use a stable, validated result before a transition starts. Keep playback and fallback independent of analysis failure.
5. Run end-to-end device tests (local/stream/hybrid; seek, queue and mode changes, stalls, pause/resume), true-peak measurements and blind listening before enabling complex transitions/FX.
