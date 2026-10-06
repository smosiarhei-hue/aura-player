#include "StreamAudioProbe.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#define PROBE_FRAMES 1024

typedef struct {
    atomic_flag busy;
    float samples[PROBE_FRAMES];
    size_t next, count;
    unsigned long generation, consumed;
    double sampleRate;
    int supportsFloat;
} Probe;

static void probeInit(MTAudioProcessingTapRef tap, void *info, void **storage) {
    (void)tap; (void)info;
    Probe *p = calloc(1, sizeof(Probe));
    if (p) atomic_flag_clear(&p->busy);
    *storage = p;
}
static void probeFinalize(MTAudioProcessingTapRef tap) { free(MTAudioProcessingTapGetStorage(tap)); }
static void probePrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *format) {
    (void)maxFrames;
    Probe *p = MTAudioProcessingTapGetStorage(tap);
    if (!p || atomic_flag_test_and_set_explicit(&p->busy, memory_order_acquire)) return;
    p->sampleRate = format->mSampleRate;
    p->supportsFloat = format->mFormatID == kAudioFormatLinearPCM &&
        (format->mFormatFlags & kAudioFormatFlagIsFloat) && format->mBitsPerChannel == 32;
    p->next = p->count = 0;
    atomic_flag_clear_explicit(&p->busy, memory_order_release);
}
static void probeUnprepare(MTAudioProcessingTapRef tap) { (void)tap; }
static void probeProcess(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
                         AudioBufferList *buffers, CMItemCount *framesOut, MTAudioProcessingTapFlags *flagsOut) {
    (void)flags;
    // Always return Apple's source audio unchanged, even when capture is skipped.
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, NULL, framesOut);
    if (status != noErr) { *framesOut = 0; return; }
    Probe *p = MTAudioProcessingTapGetStorage(tap);
    if (!p || atomic_flag_test_and_set_explicit(&p->busy, memory_order_acquire)) return;
    if (!p->supportsFloat) { atomic_flag_clear_explicit(&p->busy, memory_order_release); return; }
    for (CMItemCount frame = 0; frame < *framesOut; frame++) {
        float mono = 0; unsigned channels = 0;
        for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
            const AudioBuffer *buffer = &buffers->mBuffers[b];
            if (!buffer->mData || !buffer->mNumberChannels) continue;
            const float *data = buffer->mData;
            size_t length = buffer->mDataByteSize / sizeof(float);
            for (UInt32 ch = 0; ch < buffer->mNumberChannels; ch++) {
                size_t offset = (size_t)frame * buffer->mNumberChannels + ch;
                if (offset < length && isfinite(data[offset])) { mono += data[offset]; channels++; }
            }
        }
        p->samples[p->next] = channels ? mono / channels : 0;
        p->next = (p->next + 1) % PROBE_FRAMES;
        if (p->count < PROBE_FRAMES) p->count++;
    }
    p->generation++;
    atomic_flag_clear_explicit(&p->busy, memory_order_release);
}
MTAudioProcessingTapRef SonivoStreamProbeCreate(void) {
    // Apple's callback struct is packed to four-byte alignment. A constant aggregate
    // with function-pointer relocations can fail arm64 chained-fixup linking.
    // Volatile scalar stores construct it on the stack, not in a packed const table.
    volatile MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = NULL;
    callbacks.init = probeInit;
    callbacks.finalize = probeFinalize;
    callbacks.prepare = probePrepare;
    callbacks.unprepare = probeUnprepare;
    callbacks.process = probeProcess;
    MTAudioProcessingTapRef tap = NULL;
    OSStatus result = MTAudioProcessingTapCreate(kCFAllocatorDefault, (const MTAudioProcessingTapCallbacks *)&callbacks,
        kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
    return result == noErr ? tap : NULL;
}
size_t SonivoStreamProbeRead(MTAudioProcessingTapRef tap, float *output, size_t capacity, double *sampleRate) {
    Probe *p = MTAudioProcessingTapGetStorage(tap);
    if (!p || capacity < PROBE_FRAMES || atomic_flag_test_and_set_explicit(&p->busy, memory_order_acquire)) return 0;
    size_t count = 0;
    if (p->count == PROBE_FRAMES && p->generation != p->consumed) {
        for (size_t i = 0; i < PROBE_FRAMES; i++) output[i] = p->samples[(p->next + i) % PROBE_FRAMES];
        *sampleRate = p->sampleRate;
        p->consumed = p->generation;
        count = PROBE_FRAMES;
    }
    atomic_flag_clear_explicit(&p->busy, memory_order_release);
    return count;
}
