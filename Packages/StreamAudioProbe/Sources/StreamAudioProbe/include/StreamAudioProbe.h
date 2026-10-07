#ifndef SONIVO_STREAM_AUDIO_PROBE_H
#define SONIVO_STREAM_AUDIO_PROBE_H
#include <MediaToolbox/MediaToolbox.h>
#include <stddef.h>
#include <AudioToolbox/AudioToolbox.h>
// All audio-thread callbacks are C functions: no Swift actor/executor crossing.
MTAudioProcessingTapRef _Nullable SonivoStreamProbeCreate(void) CF_RETURNS_RETAINED;
size_t SonivoStreamProbeRead(MTAudioProcessingTapRef _Nonnull tap,
                            float * _Nonnull output, size_t capacity,
                            double * _Nonnull sampleRate);
// Next chronological 1024-sample PCM window (256-sample hop), with asset centre time.
// NAN means the source did not provide valid timing. No invented timestamp.
size_t SonivoStreamProbeReadTimed(MTAudioProcessingTapRef _Nonnull tap,
    float * _Nonnull output, size_t capacity, double * _Nonnull sampleRate,
    double * _Nullable mediaTime);
unsigned long long SonivoStreamProbeDroppedWindows(MTAudioProcessingTapRef _Nonnull tap);
// Cumulative diagnostics per tap, including across prepare/seek epochs.
unsigned long long SonivoStreamProbeSkipped(MTAudioProcessingTapRef _Nonnull tap);
unsigned long long SonivoStreamProbeUnstamped(MTAudioProcessingTapRef _Nonnull tap);
// Original prepare ASBD. 1 = coherent snapshot, 0 = absent/in-progress; output unchanged on 0.
int SonivoStreamProbeFormat(MTAudioProcessingTapRef _Nonnull tap,
                           AudioStreamBasicDescription * _Nonnull format);
// Native-code EQ runs on the PCM that AVPlayer is already decoding; no file cache.
void SonivoStreamProbeSetEQ(MTAudioProcessingTapRef _Nonnull tap, const float * _Nonnull gains,
                           size_t count, int enabled);
// 0 preparing, 1 Float32 PCM ready, -1 unsupported. Original audio is always retained.
int SonivoStreamProbeEQReady(MTAudioProcessingTapRef _Nonnull tap);
float SonivoStreamEQPreamp(const float * _Nonnull gains, size_t count, double sampleRate);
#endif
