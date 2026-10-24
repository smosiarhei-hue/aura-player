#include "RealtimeEQ.h"
#include <math.h>
#include <string.h>

static const double frequencies[SONIVO_EQ_BANDS] = {40, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 15000};
static double clamp(double x, double lo, double hi) { return fmax(lo, fmin(hi, x)); }
static double cleanGain(double gain, unsigned band) { return isfinite(gain) ? clamp(gain, -12, frequencies[band] <= 250 ? 18 : 12) : 0; }
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
        // One-octave parametric width matches the native local EQ.
        // 60 Hz sits only 0.585 octaves above the bass shelf. A narrower
        // bell prevents the two controls from piling up a broad low-mid hump.
        double bandwidth = band == 1 ? .75 : 1;
        double alpha = sn * sinh(0.34657359027997265 * bandwidth * w / fmax(sn, 1e-9));
        b0=1+alpha*A; b1=-2*c; b2=1-alpha*A;
        a0=1+alpha/A; a1=-2*c; a2=1-alpha/A;
    }
    return (SonivoEQCoefficients){b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};
}

// Theoretical small-signal cascade response, before dynamic peak protection.
// UI/control-thread only. Same coefficients as the audio renderer, no copied math.
void SonivoEQResponse(const float *gains,size_t count,double sampleRate,float *output,size_t points) {
    if(!output || !points) return;
    double rate=isfinite(sampleRate) && sampleRate>=8000?sampleRate:48000;
    SonivoEQCoefficients k[SONIVO_EQ_BANDS];
    for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) k[b]=coefficients(b,cleanGain(gains && b<count?gains[b]:0,b),rate);
    double top=fmin(20000,rate*.44);
    for(size_t i=0;i<points;i++) {
        double hz=20*pow(top/20,points>1?(double)i/(points-1):0);
        double w=6.283185307179586*hz/rate,c=cos(w),s=sin(w),c2=cos(2*w),s2=sin(2*w),db=0;
        for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) {
            double nr=k[b].b0+k[b].b1*c+k[b].b2*c2,ni=-k[b].b1*s-k[b].b2*s2;
            double dr=1+k[b].a1*c+k[b].a2*c2,di=-k[b].a1*s-k[b].a2*s2;
            db+=10*log10(fmax(nr*nr+ni*ni,1e-30)/fmax(dr*dr+di*di,1e-30));
        }
        output[i]=(float)db;
    }
}

// Unity preamp by product policy: do not turn down the whole song whenever a
// slider is boosted. The linked sample-peak guard handles actual overshoots.
float SonivoEQPreamp(const float *gains, size_t count, double rate) {
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
        atomic_store_explicit(&eq->gains[b],(int)lrint(cleanGain(gains && b<count?gains[b]:0,b)*1000),memory_order_relaxed);
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
    for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) nonflat |= values[b]!=0;
    int wantsWet=enabled && nonflat;
    int changed=wantsWet!=eq->wantsWet;
    // Fade the complete protected EQ signal, not identity filters + a quickly
    // released preamp: that combination used to restore 18+ dB in milliseconds.
    if(wantsWet || initial) {
        for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) {
            eq->targetDB[b]=(double)values[b]/1000;
            eq->target[b]=coefficients(b,eq->targetDB[b],eq->sampleRate);
            if(initial || eq->wet==0) {
                eq->gainDB[b]=eq->targetDB[b];eq->current[b]=eq->target[b];
            }
        }
        eq->targetPreGain=wantsWet?pow(10,(double)preamp/20000):1;
        if(eq->wet==0) eq->preGain=eq->targetPreGain;
    }
    if(changed && !initial) {
        double attenuation=fabs(20*log10(fmax(eq->preGain,1e-12)));
        double seconds=clamp(.35+attenuation/24,.35,2);
        eq->wetStart=eq->wet;eq->wetTarget=wantsWet?1:0;
        eq->wetPosition=0;eq->wetFrames=(size_t)ceil(eq->sampleRate*seconds);
    }
    eq->wantsWet=wantsWet;
    eq->appliedSequence=seq;
    if(initial) {
        eq->wet=eq->wetTarget=wantsWet?1:0;eq->wetStart=eq->wet;
        eq->wetFrames=eq->wetPosition=0;
        eq->preGain=eq->targetPreGain;
    }
}
void SonivoEQPrepare(SonivoRealtimeEQ *eq,double rate) {
    eq->sampleRate=isfinite(rate) && rate>=8000?rate:48000;
    eq->coefficientAlpha=1-exp(-16/(eq->sampleRate*.030));
    eq->sampleAlpha=1-exp(-1/(eq->sampleRate*.025));
    eq->headroomAttackAlpha=1-exp(-1/(eq->sampleRate*.001));
    // Hold across a complete 20 Hz cycle; no gain recovery between bass peaks.
    eq->releaseAlpha=1-exp(-1/(eq->sampleRate*.200));
    eq->peakHoldFrames=(size_t)ceil(eq->sampleRate*.050);eq->peakHold=0;
    memset(eq->z1,0,sizeof(eq->z1)); memset(eq->z2,0,sizeof(eq->z2));
    for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) eq->current[b]=eq->target[b]=identity();
    eq->wet=0;eq->preGain=1;eq->limiter=1;eq->rampCounter=0;
    memset(eq->gainDB,0,sizeof(eq->gainDB));memset(eq->targetDB,0,sizeof(eq->targetDB));
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
                // Smooth physical gain, not arbitrary denominator coefficients.
                // Each intermediate filter is a valid RBJ design; recompute only
                // while moving (16-sample control cadence, no allocations/locks).
                double delta=eq->targetDB[b]-eq->gainDB[b];
                if(fabs(delta)>1e-5) {
                    eq->gainDB[b]+=delta*eq->coefficientAlpha;
                    eq->current[b]=coefficients(b,eq->gainDB[b],eq->sampleRate);
                } else if(eq->gainDB[b]!=eq->targetDB[b]) {
                    eq->gainDB[b]=eq->targetDB[b];eq->current[b]=eq->target[b];
                }
            }
        }
        if(eq->wetPosition<eq->wetFrames) {
            double t=(double)++eq->wetPosition/(double)eq->wetFrames;
            double eased=t*t*(3-2*t);
            eq->wet=eq->wetStart+(eq->wetTarget-eq->wetStart)*eased;
        } else eq->wet=eq->wetTarget;
        // Fast but continuous 1 ms headroom attack; 25 ms level recovery.
        // The linked peak guard catches any overshoot during this transition.
        double headroomAlpha=targetGain<eq->preGain?eq->headroomAttackAlpha:eq->sampleAlpha;
        eq->preGain+=(targetGain-eq->preGain)*headroomAlpha;
        double result[SONIVO_EQ_CHANNELS], original[SONIVO_EQ_CHANNELS];
        for(unsigned ch=0;ch<count;ch++) {
            double dry=channels[ch][f*strides[ch]]; if(!isfinite(dry)) dry=0;
            double wet=dry;
            for(unsigned b=0;b<SONIVO_EQ_BANDS;b++) wet=filter(eq,ch,b,wet);
            original[ch]=dry;
            result[ch]=wet*eq->preGain;
        }
        // Zero-lookahead sample-peak safety, NOT a true-peak/loudness processor.
        // One envelope for all channels preserves stereo/multichannel balance.
        double peak=0;
        for(unsigned ch=0;ch<count;ch++) peak=fmax(peak,fabs(result[ch]));
        double required=peak>.98?.98/peak:1;
        if(required<=eq->limiter) {
            eq->limiter=required;eq->peakHold=eq->peakHoldFrames;
        } else if(eq->peakHold) {
            eq->peakHold--;
        } else {
            eq->limiter+=(required-eq->limiter)*eq->releaseAlpha;
        }
        // Protect the wet path BEFORE mixing. Disabling EQ releases into the
        // unchanged dry signal, not a dry signal held down by the old limiter.
        // No delay line, no new audio/lyrics synchronization offset.
        for(unsigned ch=0;ch<count;ch++) {
            double protectedWet=result[ch]*eq->limiter;
            channels[ch][f*strides[ch]]=(float)(original[ch]*(1-eq->wet)+protectedWet*eq->wet);
        }
    }
}
