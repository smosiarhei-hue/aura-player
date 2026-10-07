#ifndef SONIVO_REALTIME_EQ_H
#define SONIVO_REALTIME_EQ_H
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#define SONIVO_EQ_BANDS 10
#define SONIVO_EQ_CHANNELS 8

typedef struct { double b0, b1, b2, a1, a2; } SonivoEQCoefficients;
typedef struct {
    atomic_uint sequence;
    atomic_int enabled, gains[SONIVO_EQ_BANDS], preamp;
    unsigned appliedSequence;
    double sampleRate, wet, preGain, targetPreGain, limiter;
    double coefficientAlpha, sampleAlpha, releaseAlpha;
    SonivoEQCoefficients current[SONIVO_EQ_BANDS], target[SONIVO_EQ_BANDS];
    double z1[SONIVO_EQ_CHANNELS][SONIVO_EQ_BANDS], z2[SONIVO_EQ_CHANNELS][SONIVO_EQ_BANDS];
    int wantsWet, initialized;
    unsigned rampCounter;
} SonivoRealtimeEQ;
void SonivoEQInit(SonivoRealtimeEQ *eq);
void SonivoEQPrepare(SonivoRealtimeEQ *eq, double sampleRate);
// One control-thread writer, atomic mailbox; the render thread never waits for it.
void SonivoEQSet(SonivoRealtimeEQ *eq, const float *gains, size_t count, int enabled, float preamp);
void SonivoEQProcess(SonivoRealtimeEQ *eq, float **channels, const size_t *strides, unsigned count, size_t frames);
float SonivoEQPreamp(const float *gains, size_t count, double sampleRate);
#endif
