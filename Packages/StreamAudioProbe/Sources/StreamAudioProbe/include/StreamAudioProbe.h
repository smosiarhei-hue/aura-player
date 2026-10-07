#ifndef SONIVO_STREAM_AUDIO_PROBE_H
#define SONIVO_STREAM_AUDIO_PROBE_H
#include <MediaToolbox/MediaToolbox.h>
#include <stddef.h>
// All audio-thread callbacks are C functions: no Swift actor/executor crossing.
MTAudioProcessingTapRef _Nullable SonivoStreamProbeCreate(void) CF_RETURNS_RETAINED;
size_t SonivoStreamProbeRead(MTAudioProcessingTapRef _Nonnull tap,
                            float * _Nonnull output, size_t capacity,
                            double * _Nonnull sampleRate);
// Native-code EQ runs on the PCM that AVPlayer is already decoding; no file cache.
void SonivoStreamProbeSetEQ(MTAudioProcessingTapRef _Nonnull tap, const float * _Nonnull gains,
                           size_t count, int enabled);
// 0 preparing, 1 Float32 PCM ready, -1 unsupported. Original audio is always retained.
int SonivoStreamProbeEQReady(MTAudioProcessingTapRef _Nonnull tap);
float SonivoStreamEQPreamp(const float * _Nonnull gains, size_t count, double sampleRate);
#endif
