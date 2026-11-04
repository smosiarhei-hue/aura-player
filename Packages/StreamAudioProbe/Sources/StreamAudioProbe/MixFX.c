#include "MixFX.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static float clampf(float x, float lo, float hi) {
    return fminf(hi, fmaxf(lo, x));
}

void SonivoMixFXInit(SonivoMixFX *fx) {
    memset(fx, 0, sizeof(*fx));
    atomic_init(&fx->echoWet, 0);
    atomic_init(&fx->echoFeedback, 0);
    atomic_init(&fx->delayMs, 375);
    atomic_init(&fx->reverbWet, 0);
    fx->sampleRate = 48000;
}

void SonivoMixFXPrepare(SonivoMixFX *fx, double sampleRate) {
    double rate = isfinite(sampleRate) && sampleRate >= 8000 ? sampleRate : 48000;
    size_t need = (size_t)ceil(rate * SONIVO_MIXFX_MAX_DELAY_SEC) + 8;
    if (fx->delayBuf && fx->delayCap == need && fabs(fx->sampleRate - rate) < 0.5) {
        fx->prepared = 1;
        return;
    }
    free(fx->delayBuf);
    fx->delayBuf = calloc(need, sizeof(float));
    fx->delayCap = fx->delayBuf ? need : 0;
    fx->delayPos = 0;
    fx->reverbL = 0;
    fx->reverbR = 0;
    fx->sampleRate = rate;
    fx->prepared = fx->delayBuf != NULL;
}

void SonivoMixFXReset(SonivoMixFX *fx) {
    if (fx->delayBuf && fx->delayCap) memset(fx->delayBuf, 0, fx->delayCap * sizeof(float));
    fx->delayPos = 0;
    fx->reverbL = 0;
    fx->reverbR = 0;
}

void SonivoMixFXDestroy(SonivoMixFX *fx) {
    free(fx->delayBuf);
    fx->delayBuf = NULL;
    fx->delayCap = 0;
    fx->prepared = 0;
}

void SonivoMixFXSet(SonivoMixFX *fx, float echoWet, float echoFeedback, float delaySec, float reverbWet) {
    int wet = (int)lrintf(clampf(isfinite(echoWet) ? echoWet : 0, 0, 1) * 1000);
    int fb = (int)lrintf(clampf(isfinite(echoFeedback) ? echoFeedback : 0, 0, 1) * 1000);
    int ms = (int)lrintf(clampf(isfinite(delaySec) ? (float)(delaySec * 1000.0) : 375, 50, 2000));
    int rev = (int)lrintf(clampf(isfinite(reverbWet) ? reverbWet : 0, 0, 1) * 1000);
    atomic_store_explicit(&fx->echoWet, wet, memory_order_relaxed);
    atomic_store_explicit(&fx->echoFeedback, fb, memory_order_relaxed);
    atomic_store_explicit(&fx->delayMs, ms, memory_order_relaxed);
    atomic_store_explicit(&fx->reverbWet, rev, memory_order_relaxed);
}

void SonivoMixFXProcess(SonivoMixFX *fx, float **channels, const size_t *strides,
                        unsigned count, size_t frames) {
    if (!fx || !fx->prepared || !fx->delayBuf || !channels || count == 0 || frames == 0) return;
    float echoWet = atomic_load_explicit(&fx->echoWet, memory_order_relaxed) / 1000.f;
    float echoFb = atomic_load_explicit(&fx->echoFeedback, memory_order_relaxed) / 1000.f;
    float reverbWet = atomic_load_explicit(&fx->reverbWet, memory_order_relaxed) / 1000.f;
    int delayMs = atomic_load_explicit(&fx->delayMs, memory_order_relaxed);
    if (echoWet < 0.001f && reverbWet < 0.001f) return;

    size_t delayFrames = (size_t)llround(fmax(1.0, fx->sampleRate * (double)delayMs / 1000.0));
    if (delayFrames >= fx->delayCap) delayFrames = fx->delayCap - 1;
    float damp = 0.82f;

    for (size_t f = 0; f < frames; f++) {
        float dry = 0;
        for (unsigned ch = 0; ch < count && ch < SONIVO_MIXFX_CHANNELS; ch++) {
            dry += channels[ch][f * strides[ch]];
        }
        dry /= (float)count;

        size_t readPos = fx->delayPos >= delayFrames
            ? fx->delayPos - delayFrames
            : fx->delayCap - (delayFrames - fx->delayPos);
        float delayed = fx->delayBuf[readPos];
        float written = dry + delayed * echoFb * 0.95f;
        if (!isfinite(written)) written = 0;
        fx->delayBuf[fx->delayPos] = written;
        fx->delayPos++;
        if (fx->delayPos >= fx->delayCap) fx->delayPos = 0;

        /* One-pole feedback “plate” on a slower tap — musical wash, not HRTF. */
        float plateIn = dry * 0.55f + delayed * 0.45f;
        fx->reverbL = fx->reverbL * damp + plateIn * (1.f - damp);
        fx->reverbR = fx->reverbR * damp + fx->reverbL * (1.f - damp);
        float plate = (fx->reverbL + fx->reverbR) * 0.5f;

        for (unsigned ch = 0; ch < count && ch < SONIVO_MIXFX_CHANNELS; ch++) {
            float sample = channels[ch][f * strides[ch]];
            sample += delayed * echoWet * 0.85f;
            sample += plate * reverbWet * 0.70f;
            if (!isfinite(sample)) sample = 0;
            channels[ch][f * strides[ch]] = sample;
        }
    }
}
