#ifndef SONIVO_STREAM_EQ_H
#define SONIVO_STREAM_EQ_H

#include <MediaToolbox/MediaToolbox.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

MTAudioProcessingTapRef SonivoCreateStreamEQTap(void);
void SonivoStreamEQSetEnabled(bool enabled);
void SonivoStreamEQSetGains(const float *gains, int count);

#ifdef __cplusplus
}
#endif

#endif
