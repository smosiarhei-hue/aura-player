#include "StreamAudioProbe.h"
#include "RealtimeEQ.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#define PROBE_FRAMES 1024

typedef struct {
    atomic_flag busy;
    SonivoRealtimeEQ eq;
    atomic_int eqReady;
    atomic_uint eqRate;
    unsigned channels;
    float samples[PROBE_FRAMES];
    size_t next, count;
    unsigned long generation, consumed;
    int supportsFloat;
} Probe;

static void probeInit(MTAudioProcessingTapRef tap, void *info, void **storage) {
    (void)tap; (void)info;
    Probe *p = calloc(1, sizeof(Probe));
    if (p) {
        atomic_flag_clear(&p->busy);
        atomic_init(&p->eqReady,0); atomic_init(&p->eqRate,48000);
        SonivoEQInit(&p->eq);
    }
    *storage = p;
}
static void probeFinalize(MTAudioProcessingTapRef tap) { free(MTAudioProcessingTapGetStorage(tap)); }
static void probePrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *format) {
    (void)maxFrames;
    Probe *p = MTAudioProcessingTapGetStorage(tap);
    if (!p) return;
    p->channels=format->mChannelsPerFrame;
    p->supportsFloat = format->mFormatID == kAudioFormatLinearPCM &&
        (format->mFormatFlags & kAudioFormatFlagIsFloat) && format->mBitsPerChannel == 32 &&
        !(format->mFormatFlags & kAudioFormatFlagIsBigEndian) && p->channels>0 && p->channels<=SONIVO_EQ_CHANNELS &&
        format->mBytesPerFrame==sizeof(float)*((format->mFormatFlags & kAudioFormatFlagIsNonInterleaved)?1:p->channels);
    SonivoEQPrepare(&p->eq,format->mSampleRate);
    atomic_store_explicit(&p->eqRate,(unsigned)format->mSampleRate,memory_order_release);
    atomic_store_explicit(&p->eqReady,p->supportsFloat?1:-1,memory_order_release);
    if (atomic_flag_test_and_set_explicit(&p->busy,memory_order_acquire)) return;
    p->next=p->count=0;
    atomic_flag_clear_explicit(&p->busy,memory_order_release);
}
static void probeUnprepare(MTAudioProcessingTapRef tap) {
    Probe *p=MTAudioProcessingTapGetStorage(tap);
    if(p) atomic_store_explicit(&p->eqReady,0,memory_order_release);
}
static void processEQ(Probe *p,AudioBufferList *buffers,CMItemCount frames) {
    if (!p->supportsFloat || frames<=0) return;
    float *channels[SONIVO_EQ_CHANNELS];size_t strides[SONIVO_EQ_CHANNELS];unsigned count=0;
    for(UInt32 b=0;b<buffers->mNumberBuffers;b++) {
        AudioBuffer *buffer=&buffers->mBuffers[b];
        unsigned n=buffer->mNumberChannels;
        if(!buffer->mData || !n || n>SONIVO_EQ_CHANNELS || count+n>SONIVO_EQ_CHANNELS ||
           buffer->mDataByteSize/sizeof(float)<(size_t)frames*n) return;
        for(unsigned ch=0;ch<n;ch++) { channels[count]=(float *)buffer->mData+ch;strides[count]=n;count++; }
    }
    if(count==p->channels) SonivoEQProcess(&p->eq,channels,strides,count,(size_t)frames);
}
static void probeProcess(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
                         AudioBufferList *buffers, CMItemCount *framesOut, MTAudioProcessingTapFlags *flagsOut) {
    (void)flags;
    // Source decoded by Apple; apply EQ in-place only to supported PCM, preserving channels.
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, NULL, framesOut);
    if (status != noErr) { *framesOut = 0; return; }
    Probe *p = MTAudioProcessingTapGetStorage(tap);
    if (!p) return;
    processEQ(p,buffers,*framesOut);
    // Spectrum capture may be skipped; DSP must never be skipped by a UI read lock.
    if (atomic_flag_test_and_set_explicit(&p->busy, memory_order_acquire)) return;
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
        *sampleRate = atomic_load_explicit(&p->eqRate,memory_order_acquire);
        p->consumed = p->generation;
        count = PROBE_FRAMES;
    }
    atomic_flag_clear_explicit(&p->busy, memory_order_release);
    return count;
}

void SonivoStreamProbeSetEQ(MTAudioProcessingTapRef tap,const float *gains,size_t count,int enabled) {
    Probe *p=MTAudioProcessingTapGetStorage(tap);if(!p) return;
    double rate=atomic_load_explicit(&p->eqRate,memory_order_acquire);
    float preamp=SonivoEQPreamp(gains,count,rate);
    SonivoEQSet(&p->eq,gains,count,enabled,preamp);
}
int SonivoStreamProbeEQReady(MTAudioProcessingTapRef tap) {
    Probe *p=MTAudioProcessingTapGetStorage(tap);
    return p?atomic_load_explicit(&p->eqReady,memory_order_acquire):-1;
}
float SonivoStreamEQPreamp(const float *gains,size_t count,double sampleRate) {
    return SonivoEQPreamp(gains,count,sampleRate);
}
