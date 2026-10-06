#ifndef SONIVO_STREAM_AUDIO_PROBE_H
#define SONIVO_STREAM_AUDIO_PROBE_H
#include <MediaToolbox/MediaToolbox.h>
#include <stddef.h>
// All audio-thread callbacks are C functions: no Swift actor/executor crossing.
MTAudioProcessingTapRef _Nullable SonivoStreamProbeCreate(void) CF_RETURNS_RETAINED;
size_t SonivoStreamProbeRead(MTAudioProcessingTapRef _Nonnull tap,
                            float * _Nonnull output, size_t capacity,
                            double * _Nonnull sampleRate);
#endif
