#include "RealtimeEQ.h"
#include <math.h>
#include <string.h>

static const double frequencies[SONIVO_EQ_BANDS] = {30, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 20000};
static double clamp(double x, double lo, double hi) { return fmax(lo, fmin(hi, x)); }
static double cleanGain(double gain) { return isfinite(gain) ? clamp(gain, -12, 12) : 0; }
static SonivoEQCoefficients identity(void) { return (SonivoEQCoefficients){1,0,0,0,0}; }
static SonivoEQCoefficients coefficients(unsigned band, double gain, double rate) {
    if (fabs(gain) < 0.00001) return identity();
    double w = 6.283185307179586 * fmin(frequencies[band], rate * 0.44) / rate;
    double c = cos(w), sn = sin(w), A = pow(10, gain / 40);
    double b0, b1, b2, a0, a1, a2;
    if (band == 0 || band == SONIVO_EQ_BANDS - 1) {
        // RBJ shelves, slope S=1: broad bass/treble controls, not narrow edge resonances.
        double alpha = sn * 0.7071067811865476, beta = 2 * sqrt(A) * alpha;
        if (band == 0) {
            b0=A*((A+1)-(A-1)*c+beta); b1=2*A*((A-1)-(A+1)*c); b2=A*((A+1)-(A-1)*c-beta);
            a0=(A+1)+(A-1)*c+beta; a1=-2*((A-1)+(A+1)*c); a2=(A+1)+(A-1)*c-beta;
        } else {
            b0=A*((A+1)+(A-1)*c+beta); b1=-2*A*((A-1)+(A+1)*c); b2=A*((A+1)+(A-1)*c-beta);
            a0=(A+1)-(A-1)*c+beta; a1=2*((A-1)-(A+1)*c); a2=(A+1)-(A-1)*c-beta;
        }
    } else {
        // One-octave peaking filters match the native local EQ's bandwidth.
        double alpha = sn * sinh(0.34657359027997265 * w / fmax(sn, 1e-9));
        b0=1+alpha*A; b1=-2*c; b2=1-alpha*A;
        a0=1+alpha/A; a1=-2*c; a2=1-alpha/A;
    }
    return (SonivoEQCoefficients){b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};
}

float SonivoEQPreamp(const float *gains, size_t count, double rate) {
    // Requested unprotected EQ: boosts no longer turn down the entire signal.
    // Retain the API for both native AU and streamed PCM settings publishers.
    (void)gains; (void)count; (void)rate;
    return 0;
}

void SonivoEQInit(SonivoRealtimeEQ *eq) {
    memset(eq,0,sizeof(*eq));
    atomic_init(&eq->sequence,0); atomic_init(&eq->enabled,0); atomic_init(&eq->preamp,0);
    for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) atomic_init(&eq->gains[b],0);
    eq->sampleRate=48000; eq->preGain=1; eq->limiter=1;
}
void SonivoEQSet(SonivoRealtimeEQ *eq,const float *gains,size_t count,int enabled,float preamp) {
    atomic_fetch_add_explicit(&eq->sequence,1,memory_order_acq_rel);
    atomic_store_explicit(&eq->enabled,enabled!=0,memory_order_relaxed);
    atomic_store_explicit(&eq->preamp,(int)lrint(clamp(isfinite(preamp)?preamp:0,-48,0)*1000),memory_order_relaxed);
    for(unsigned b=0;b<SONIVO_EQ_BANDS;b++)
        atomic_store_explicit(&eq->gains[b],(int)lrint(cleanGain(gains && b<count?gains[b]:0)*1000),memory_order_relaxed);
    atomic_fetch_add_explicit(&eq->sequence,1,memory_order_release);
}
static void consume(SonivoRealtimeEQ *eq,int initial) {
    unsigned seq=atomic_load_explicit(&eq->sequence,memory_order_acquire);
    if ((seq&1) || (!initial && seq==eq->appliedSequence)) return;
    int enabled=atomic_load_explicit(&eq->enabled,memory_order_relaxed);
    int preamp=atomic_load_explicit(&eq->preamp,memory_order_relaxed), values[SONIVO_EQ_BANDS];
    for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) values[b]=atomic_load_explicit(&eq->gains[b],memory_order_relaxed);
    atomic_thread_fence(memory_order_acquire);
    if (seq!=atomic_load_explicit(&eq->sequence,memory_order_relaxed)) return;
    int nonflat=0;
    for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) {
        nonflat |= values[b]!=0;
        eq->target[b]=coefficients(b,enabled?(double)values[b]/1000:0,eq->sampleRate);
        if(initial) eq->current[b]=eq->target[b];
    }
    eq->wantsWet=enabled && nonflat;
    eq->targetPreGain=eq->wantsWet?pow(10,(double)preamp/20000):1;
    eq->appliedSequence=seq;
    if (initial) { eq->wet=eq->wantsWet?1:0; eq->preGain=eq->wantsWet?pow(10,(double)preamp/20000):1; }
}
void SonivoEQPrepare(SonivoRealtimeEQ *eq,double rate) {
    eq->sampleRate=isfinite(rate) && rate>=8000?rate:48000;
    eq->coefficientAlpha=1-exp(-16/(eq->sampleRate*.030));
    eq->sampleAlpha=1-exp(-1/(eq->sampleRate*.025));
    eq->releaseAlpha=1-exp(-1/(eq->sampleRate*.080));
    memset(eq->z1,0,sizeof(eq->z1)); memset(eq->z2,0,sizeof(eq->z2));
    for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) eq->current[b]=eq->target[b]=identity();
    eq->wet=0;eq->preGain=1;eq->limiter=1;eq->rampCounter=0;
    consume(eq,1);eq->initialized=1;
}
static double filter(SonivoRealtimeEQ *eq,unsigned ch,unsigned b,double x) {
    SonivoEQCoefficients k=eq->current[b];
    double y=k.b0*x+eq->z1[ch][b];
    eq->z1[ch][b]=k.b1*x-k.a1*y+eq->z2[ch][b];
    eq->z2[ch][b]=k.b2*x-k.a2*y;
    if (!isfinite(y) || !isfinite(eq->z1[ch][b]) || !isfinite(eq->z2[ch][b])) {
        eq->z1[ch][b]=eq->z2[ch][b]=0;return x;
    }
    if(fabs(eq->z1[ch][b])<1e-24) eq->z1[ch][b]=0;
    if(fabs(eq->z2[ch][b])<1e-24) eq->z2[ch][b]=0;
    return y;
}
void SonivoEQProcess(SonivoRealtimeEQ *eq,float **channels,const size_t *strides,unsigned count,size_t frames) {
    if (!eq->initialized || !count || count>SONIVO_EQ_CHANNELS) return;
    consume(eq,0);
    if(!eq->wantsWet && eq->wet<0.00001) {
        eq->wet=0;eq->preGain=1;eq->limiter=1;
        memset(eq->z1,0,sizeof(eq->z1));memset(eq->z2,0,sizeof(eq->z2));return;
    }
    double targetGain=eq->targetPreGain;
    for(size_t f=0;f<frames;f++) {
        if((eq->rampCounter++ & 15)==0) {
            for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) {
                double a=eq->coefficientAlpha;
                eq->current[b].b0+=(eq->target[b].b0-eq->current[b].b0)*a;
                eq->current[b].b1+=(eq->target[b].b1-eq->current[b].b1)*a;
                eq->current[b].b2+=(eq->target[b].b2-eq->current[b].b2)*a;
                eq->current[b].a1+=(eq->target[b].a1-eq->current[b].a1)*a;
                eq->current[b].a2+=(eq->target[b].a2-eq->current[b].a2)*a;
            }
        }
        eq->wet+=((eq->wantsWet?1:0)-eq->wet)*eq->sampleAlpha;
        eq->preGain+=(targetGain-eq->preGain)*eq->sampleAlpha;
        double result[SONIVO_EQ_CHANNELS];
        for(unsigned ch=0;ch<count;ch++) {
            double dry=channels[ch][f*strides[ch]]; if(!isfinite(dry)) dry=0;
            double wet=dry;
            for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) wet=filter(eq,ch,b,wet);
            result[ch]=dry*(1-eq->wet)+wet*eq->preGain*eq->wet;
        }
        // No app peak limiter or hard clipper: Float32 peaks may exceed unity.
        // Per-channel filters and numerical/format validity checks remain unchanged.
        for(unsigned ch=0;ch<count;ch++) channels[ch][f*strides[ch]]=(float)result[ch];
    }
}
