// Bounded single-producer/audio, single-consumer/analysis PCM windows.
// Portable C11: no Apple dependencies, waits, allocation or FFT on the audio thread.
#ifndef SONIVO_PCM_WINDOW_QUEUE_H
#define SONIVO_PCM_WINDOW_QUEUE_H
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#define SONIVO_PCM_WINDOW 1024
#define SONIVO_PCM_HOP 256
#define SONIVO_PCM_CAPACITY 256

typedef struct { float samples[SONIVO_PCM_WINDOW]; double rate,time; uint64_t epoch; } SonivoPCMWindow;
typedef struct {
    float ring[SONIVO_PCM_WINDOW]; size_t next,count,hop;
    SonivoPCMWindow slots[SONIVO_PCM_CAPACITY];
    _Atomic uint64_t written,read,epoch,dropped;
} SonivoPCMWindowQueue;
static inline void SonivoPCMInit(SonivoPCMWindowQueue *q) {
    q->next=q->count=q->hop=0;
    atomic_init(&q->written,0); atomic_init(&q->read,0);
    atomic_init(&q->epoch,1); atomic_init(&q->dropped,0);
}
// Called ONLY by the producer. Reader owns read index; never overwrite a slot in use.
static inline void SonivoPCMReset(SonivoPCMWindowQueue *q) {
    q->next=q->count=q->hop=0;
    atomic_fetch_add_explicit(&q->epoch,1,memory_order_release);
}
static inline void SonivoPCMPush(SonivoPCMWindowQueue *q,float sample,double end,double rate) {
    q->ring[q->next]=isfinite(sample)?sample:0;
    q->next=(q->next+1)%SONIVO_PCM_WINDOW;
    if(q->count<SONIVO_PCM_WINDOW) q->count++;
    q->hop++;
    if(q->count<SONIVO_PCM_WINDOW || q->hop<SONIVO_PCM_HOP) return;
    q->hop=0;
    uint64_t write=atomic_load_explicit(&q->written,memory_order_relaxed);
    uint64_t read=atomic_load_explicit(&q->read,memory_order_acquire);
    if(write-read>=SONIVO_PCM_CAPACITY) {
        atomic_fetch_add_explicit(&q->dropped,1,memory_order_relaxed); return;
    }
    SonivoPCMWindow *slot=&q->slots[write%SONIVO_PCM_CAPACITY];
    size_t tail=SONIVO_PCM_WINDOW-q->next;
    memcpy(slot->samples,q->ring+q->next,tail*sizeof(float));
    memcpy(slot->samples+tail,q->ring,q->next*sizeof(float));
    slot->rate=rate;
    slot->time=isfinite(end)&&rate>0 ? end-(SONIVO_PCM_WINDOW*0.5)/rate : NAN;
    slot->epoch=atomic_load_explicit(&q->epoch,memory_order_acquire);
    atomic_store_explicit(&q->written,write+1,memory_order_release);
}
static inline size_t SonivoPCMPop(SonivoPCMWindowQueue *q,float *out,size_t capacity,double *rate,double *time) {
    if(capacity<SONIVO_PCM_WINDOW) return 0;
    uint64_t read=atomic_load_explicit(&q->read,memory_order_relaxed);
    uint64_t write=atomic_load_explicit(&q->written,memory_order_acquire);
    while(read<write) {
        SonivoPCMWindow *slot=&q->slots[read%SONIVO_PCM_CAPACITY];
        if(slot->epoch!=atomic_load_explicit(&q->epoch,memory_order_acquire)) {
            read++; atomic_store_explicit(&q->read,read,memory_order_release); continue;
        }
        memcpy(out,slot->samples,SONIVO_PCM_WINDOW*sizeof(float));
        *rate=slot->rate; if(time) *time=slot->time;
        atomic_store_explicit(&q->read,read+1,memory_order_release);
        return SONIVO_PCM_WINDOW;
    }
    return 0;
}
#endif
