#include "SonivoStreamEQ.h"
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define SONIVO_BANDS 10
#define SONIVO_MAX_CHANNELS 8

static const float kFrequencies[SONIVO_BANDS] = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
static _Atomic bool gEnabled = false;
static _Atomic float gGains[SONIVO_BANDS];

typedef struct {
    float b0, b1, b2, a1, a2;
    float z1[SONIVO_MAX_CHANNELS];
    float z2[SONIVO_MAX_CHANNELS];
} SonivoBiquad;

typedef struct {
    double sampleRate;
    UInt32 channels;
    bool supportedFormat;
    float appliedGains[SONIVO_BANDS];
    SonivoBiquad filters[SONIVO_BANDS];
} SonivoTapStorage;

void SonivoStreamEQSetEnabled(bool enabled) {
    atomic_store_explicit(&gEnabled, enabled, memory_order_relaxed);
}

void SonivoStreamEQSetGains(const float *gains, int count) {
    if (gains == NULL) return;
    const int limit = count < SONIVO_BANDS ? count : SONIVO_BANDS;
    for (int i = 0; i < limit; i++) {
        float value = fmaxf(-12.0f, fminf(12.0f, gains[i]));
        atomic_store_explicit(&gGains[i], value, memory_order_relaxed);
    }
}

static void ConfigureBiquad(SonivoBiquad *f, float frequency, float gain, double sampleRate) {
    const double hz = fmin((double)frequency, sampleRate * 0.45);
    const double A = pow(10.0, (double)gain / 40.0);
    const double omega = 2.0 * M_PI * hz / sampleRate;
    const double alpha = sin(omega) / 2.0;
    const double cosine = cos(omega);
    const double a0 = 1.0 + alpha / A;
    f->b0 = (float)((1.0 + alpha * A) / a0);
    f->b1 = (float)((-2.0 * cosine) / a0);
    f->b2 = (float)((1.0 - alpha * A) / a0);
    f->a1 = (float)((-2.0 * cosine) / a0);
    f->a2 = (float)((1.0 - alpha / A) / a0);
}

static void RefreshCoefficients(SonivoTapStorage *s, bool force) {
    if (s == NULL || s->sampleRate <= 0) return;
    for (int i = 0; i < SONIVO_BANDS; i++) {
        const float gain = atomic_load_explicit(&gGains[i], memory_order_relaxed);
        if (force || fabsf(gain - s->appliedGains[i]) > 0.001f) {
            s->appliedGains[i] = gain;
            ConfigureBiquad(&s->filters[i], kFrequencies[i], gain, s->sampleRate);
        }
    }
}

static void TapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **storageOut) {
    (void)tap; (void)clientInfo;
    SonivoTapStorage *s = calloc(1, sizeof(SonivoTapStorage));
    for (int i = 0; i < SONIVO_BANDS; i++) s->appliedGains[i] = NAN;
    *storageOut = s;
}

static void TapFinalize(MTAudioProcessingTapRef tap) {
    free(MTAudioProcessingTapGetStorage(tap));
}

static void TapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *format) {
    (void)maxFrames;
    SonivoTapStorage *s = MTAudioProcessingTapGetStorage(tap);
    if (s == NULL || format == NULL) return;
    s->sampleRate = format->mSampleRate;
    s->channels = format->mChannelsPerFrame;
    s->supportedFormat = format->mFormatID == kAudioFormatLinearPCM &&
        (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        format->mBitsPerChannel == 32 && s->channels > 0 && s->channels <= SONIVO_MAX_CHANNELS;
    memset(s->filters, 0, sizeof(s->filters));
    for (int i = 0; i < SONIVO_BANDS; i++) s->appliedGains[i] = NAN;
    RefreshCoefficients(s, true);
}

static void TapUnprepare(MTAudioProcessingTapRef tap) {
    SonivoTapStorage *s = MTAudioProcessingTapGetStorage(tap);
    if (s != NULL) memset(s->filters, 0, sizeof(s->filters));
}

static inline float ProcessSample(SonivoBiquad *f, float input, UInt32 channel) {
    const float output = f->b0 * input + f->z1[channel];
    f->z1[channel] = f->b1 * input - f->a1 * output + f->z2[channel];
    f->z2[channel] = f->b2 * input - f->a2 * output;
    return output;
}

static void TapProcess(MTAudioProcessingTapRef tap, CMItemCount requestedFrames,
                       MTAudioProcessingTapFlags flags, AudioBufferList *buffers,
                       CMItemCount *framesOut, MTAudioProcessingTapFlags *flagsOut) {
    (void)flags;
    CMTimeRange range = kCMTimeRangeInvalid;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, requestedFrames, buffers, flagsOut, &range, framesOut);
    if (status != noErr) { *framesOut = 0; return; }

    SonivoTapStorage *s = MTAudioProcessingTapGetStorage(tap);
    if (s == NULL || !s->supportedFormat || !atomic_load_explicit(&gEnabled, memory_order_relaxed)) return;
    RefreshCoefficients(s, false);

    UInt32 channelBase = 0;
    for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
        AudioBuffer *buffer = &buffers->mBuffers[b];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) continue;
        float *samples = (float *)buffer->mData;
        UInt32 count = buffer->mNumberChannels;
        for (CMItemCount frame = 0; frame < *framesOut; frame++) {
            for (UInt32 local = 0; local < count; local++) {
                UInt32 channel = channelBase + local;
                if (channel >= SONIVO_MAX_CHANNELS) continue;
                size_t index = (size_t)frame * count + local;
                float value = samples[index];
                for (int band = 0; band < SONIVO_BANDS; band++) value = ProcessSample(&s->filters[band], value, channel);
                samples[index] = value;
            }
        }
        channelBase += count;
    }
}

MTAudioProcessingTapRef SonivoCreateStreamEQTap(void) {
    // Xcode 26 may lower an aggregate initializer into a 4-byte-aligned
    // constant even though this structure contains pointer fields. Build the
    // callback table dynamically and require pointer alignment explicitly.
    _Alignas(void *) MTAudioProcessingTapCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = NULL;
    callbacks.init = TapInit;
    callbacks.finalize = TapFinalize;
    callbacks.prepare = TapPrepare;
    callbacks.unprepare = TapUnprepare;
    callbacks.process = TapProcess;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
        kMTAudioProcessingTapCreationFlag_PreEffects, &tap);
    return status == noErr ? tap : NULL;
}
