#ifndef SONIVO_MIX_FX_H
#define SONIVO_MIX_FX_H
#include <stddef.h>
#include <stdatomic.h>
#include <stdint.h>

/// Musical Automix send FX on the stream PCM tap (echo + light plate).
/// Not system Spatial Audio / HRTF — wet bus only, atomic mailbox from the UI thread.
#define SONIVO_MIXFX_CHANNELS 8
#define SONIVO_MIXFX_MAX_DELAY_SEC 2.0

typedef struct {
    atomic_int echoWet;      /* 0…1000 → 0…1 */
    atomic_int echoFeedback; /* 0…1000 → 0…1 */
    atomic_int delayMs;      /* 50…2000 */
    atomic_int reverbWet;    /* 0…1000 → 0…1 */
    float *delayBuf;
    size_t delayCap;
    size_t delayPos;
    float reverbL;
    float reverbR;
    double sampleRate;
    int prepared;
} SonivoMixFX;

void SonivoMixFXInit(SonivoMixFX *fx);
void SonivoMixFXPrepare(SonivoMixFX *fx, double sampleRate);
void SonivoMixFXReset(SonivoMixFX *fx);
void SonivoMixFXDestroy(SonivoMixFX *fx);
void SonivoMixFXSet(SonivoMixFX *fx, float echoWet, float echoFeedback, float delaySec, float reverbWet);
void SonivoMixFXProcess(SonivoMixFX *fx, float **channels, const size_t *strides,
                        unsigned count, size_t frames);
#endif
