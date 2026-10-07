// Portable C11 diagnostic state. One prepare-thread writer, nonblocking readers.
#ifndef SONIVO_PROBE_DIAGNOSTICS_H
#define SONIVO_PROBE_DIAGNOSTICS_H
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#define SONIVO_ASBD_FIELDS 8

typedef struct {
    _Atomic uint64_t skipped;
    atomic_uint formatSequence;
    atomic_int hasFormat;
    _Atomic uint64_t sampleRateBits;
    _Atomic uint32_t formatFields[SONIVO_ASBD_FIELDS];
} SonivoProbeDiagnostics;

static inline void SonivoProbeDiagnosticsInit(SonivoProbeDiagnostics *d) {
    atomic_init(&d->skipped,0); atomic_init(&d->formatSequence,0);
    atomic_init(&d->hasFormat,0); atomic_init(&d->sampleRateBits,0);
    for(size_t i=0;i<SONIVO_ASBD_FIELDS;i++) atomic_init(&d->formatFields[i],0);
}
static inline void SonivoProbeRecordSkipped(SonivoProbeDiagnostics *d) {
    atomic_fetch_add_explicit(&d->skipped,1,memory_order_relaxed);
}
// Same buffer conditions as processEQ before A4. No dereference or format conversion.
static inline int SonivoProbeCheckBuffer(SonivoProbeDiagnostics *d,const void *data,
                                        unsigned channels,unsigned priorChannels,
                                        unsigned channelLimit,size_t bytes,size_t frames) {
    if(!data || !channels || channels>channelLimit || priorChannels+channels>channelLimit ||
       bytes/sizeof(float)<frames*channels) {
        SonivoProbeRecordSkipped(d); return 0;
    }
    return 1;
}
static inline void SonivoProbeStoreFormat(SonivoProbeDiagnostics *d,double rate,
                                         const uint32_t fields[SONIVO_ASBD_FIELDS]) {
    _Static_assert(sizeof(double)==sizeof(uint64_t),"ASBD sample-rate representation");
    uint64_t bits;memcpy(&bits,&rate,sizeof(bits));
    atomic_fetch_add_explicit(&d->formatSequence,1,memory_order_acq_rel);
    atomic_store_explicit(&d->sampleRateBits,bits,memory_order_relaxed);
    for(size_t i=0;i<SONIVO_ASBD_FIELDS;i++)
        atomic_store_explicit(&d->formatFields[i],fields[i],memory_order_relaxed);
    atomic_store_explicit(&d->hasFormat,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&d->formatSequence,1,memory_order_release);
}
static inline int SonivoProbeLoadFormat(SonivoProbeDiagnostics *d,double *rate,
                                        uint32_t fields[SONIVO_ASBD_FIELDS]) {
    unsigned sequence=atomic_load_explicit(&d->formatSequence,memory_order_acquire);
    if((sequence&1) || !atomic_load_explicit(&d->hasFormat,memory_order_relaxed)) return 0;
    uint64_t bits=atomic_load_explicit(&d->sampleRateBits,memory_order_relaxed);
    uint32_t snapshot[SONIVO_ASBD_FIELDS];
    for(size_t i=0;i<SONIVO_ASBD_FIELDS;i++)
        snapshot[i]=atomic_load_explicit(&d->formatFields[i],memory_order_relaxed);
    atomic_thread_fence(memory_order_acquire);
    if(sequence!=atomic_load_explicit(&d->formatSequence,memory_order_relaxed)) return 0;
    memcpy(rate,&bits,sizeof(bits));memcpy(fields,snapshot,sizeof(snapshot));return 1;
}
#endif
