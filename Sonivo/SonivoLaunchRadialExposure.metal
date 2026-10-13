// Launch-only temporal exposure of a whole logo/wordmark; no Gaussian movement blur.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float launchSpring(float t, float w, float z) {
    if (t <= 0.0f) return 0.0f;
    float d = sqrt(1.0f-z*z);
    return 1.0f-exp(-z*w*t)*(cos(w*d*t)+z/d*sin(w*d*t));
}
static float launchImpact(float t, float start, float decay) {
    float u=t-start;
    return u<0.0f ? 0.0f : exp(-decay*u)*sin(28.0f*u);
}
static float launchScale(float t, float word) {
    t=clamp(t,0.0f,3.0f);
    if (t>=1.95f) return 1.0f;
    if (word>0.5f) {
        return (1.0f+0.65f*(1.0f-launchSpring(max(0.0f,t-0.82f),11.0f,0.96f)))
            *(1.0f+0.012f*launchImpact(t,1.53f,14.0f));
    }
    return (1.0f+3.6f*(1.0f-launchSpring(max(0.0f,t-0.07f),9.0f,0.94f)))
        *(1.0f+0.029f*launchImpact(t,1.12f,11.0f));
}
[[stitchable]] half4 sonivoLaunchRadialExposure(
    float2 position, SwiftUI::Layer layer, float2 size, float time, float word
) {
    if (!isfinite(time)) return layer.sample(position);
    float2 center=size*0.5f;
    float current=launchScale(time,word);
    float4 accumulated=float4(0.0f);
    // Premultiplied colors stay in the layer's linear-light working space.
    constexpr int count=24;
    for (int i=0;i<count;i++) {
        float offset=(float(i)/float(count-1)-0.5f)/60.0f;
        float sampled=launchScale(max(0.0f,time+offset),word);
        float2 sourcePosition=center+(position-center)*(current/max(sampled,0.01f));
        accumulated+=float4(layer.sample(sourcePosition));
    }
    return half4(accumulated/float(count));
}
[[stitchable]] half4 sonivoLaunchWordHighlight(
    float2 position, half4 source, float2 size, float time
) {
    float p=clamp((time-1.45f)/0.43f,0.0f,1.0f);
    if (p<=0.0f || p>=1.0f || source.a<=0.0h) return source;
    float x=position.x/max(size.x,1.0f);
    float band=exp(-pow((x-p)/0.065f,2.0f))*0.75f;
    half3 warm=half3(1.0h,0.97h,0.93h)*source.a;
    return half4(mix(source.rgb,warm,half(band)),source.a);
}
