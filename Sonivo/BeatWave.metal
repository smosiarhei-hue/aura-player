// Ferrofluid adapted from React Bits (David Haz). See docs/ferrofluid-native-handoff.md.
// License: docs/licenses/react-bits-ferrofluid-LICENSE.md.
// Visualization only: no glass plate, frame, refraction, shadow or optical second pass.
#include <metal_stdlib>
using namespace metal;
struct BeatWaveUniforms {
    float4 resolution; // xy physical pixel size; zw cosmetic bass/kick light envelopes
    float4 motion; // phase, energy, impact, detail
    float4 surface; // spring displacement, dark mode, octave count, bass envelope
    float4 colorA;
    float4 colorB;
    float4 colorC;
    float4 display; // current EDR headroom, linear-P3 output flag, reserved
};
struct BeatWaveVertex { float4 position [[position]]; float2 uv; };
vertex BeatWaveVertex beatWaveVertex(uint id [[vertex_id]]) {
    float2 p = id == 0 ? float2(-1,-1) : (id == 1 ? float2(3,-1) : float2(-1,3));
    return {float4(p,0,1), (p+1)*0.5};
}

#define uResolution u.resolution.xy
#define uBassLight u.resolution.z
#define uKickLight u.resolution.w
#define uPhase u.motion.x
#define uEnergy u.motion.y
#define uImpact u.motion.z
#define uSpringDeform u.surface.x
#define uDarkMode u.surface.y
#define uLowEnergy u.surface.w
#define uColorA u.colorA.rgb
#define uColorB u.colorB.rgb
#define uColorC u.colorC.rgb
#define uEdgeFeather 1.0
constant float FERRO_PI = 3.14159265;

// Upstream hash, sinusoidal interpolation and five-offset domain blend.
// All evaluation stays in one fragment pass: no raymarch, history texture or blur pass.
float ferroHash(float3 p) {
    p=fract(p*0.1031);
    p+=dot(p,p.zyx+33.33);
    return fract((p.x+p.y)*p.z);
}
float ferroSinlerp(float a,float b,float w) {
    return mix(a,b,(sin(w*FERRO_PI-FERRO_PI/2.0)+1.0)/2.0);
}
float ferroNoise(float2 p,float s,float seed) {
    float2 cell=floor(p/s);
    float2 rel=p-cell*s; // GLSL mod: floor semantics, including negative flow coordinates.
    float g1=ferroHash(float3(cell,seed));
    float g2=ferroHash(float3(cell.x+1.0,cell.y,seed));
    float g3=ferroHash(float3(cell.x+1.0,cell.y+1.0,seed));
    float g4=ferroHash(float3(cell.x,cell.y+1.0,seed));
    return ferroSinlerp(ferroSinlerp(g1,g2,rel.x/s),
                        ferroSinlerp(g4,g3,rel.x/s),rel.y/s);
}
float ferroDomainBlend(float2 p,float s,float seed) {
    float o=s/2.0;
    float n0=ferroNoise(p,s,seed);
    float n1=ferroNoise(p+float2(o,o),s,seed+0.1);
    float n2=ferroNoise(p+float2(-o,o),s,seed+0.2);
    float n3=ferroNoise(p+float2(o,-o),s,seed+0.3);
    float n4=ferroNoise(p+float2(-o,-o),s,seed+0.4);
    return (2.0*n0+1.5*n1+1.25*n2+1.125*n3+n4)/7.0;
}
float ferroSmoothMin(float a,float b,float k) {
    return -k*log2(exp2(-a/k)+exp2(-b/k));
}
float3 ferroPalette(float h,constant BeatWaveUniforms &u) {
    // Continuous artwork interpolation avoids abrupt colour seams between fluid lobes.
    float x=clamp(h,0.0,1.0)*2.0;
    return x<1.0 ? mix(uColorA,uColorB,smoothstep(0.0,1.0,x))
                 : mix(uColorB,uColorC,smoothstep(0.0,1.0,x-1.0));
}
// Only existing low-frequency and kick channels drive highlights; no mids/vocal input.
float ferroLightPulse(constant BeatWaveUniforms &u) {
    return clamp(clamp(uBassLight,0.0,1.0)*0.55+clamp(uKickLight,0.0,1.0)*0.80,0.0,1.0);
}
float4 evalFerrofluid(float2 uvSample,constant BeatWaveUniforms &u) {
    const float scale=1.6;
    const float fluidity=0.1;
    const float sharpness=1.8;
    const float shimmer=1.05;
    const float glow=3.0;
    float ref=700.0/scale;
    float2 p=uvSample*uResolution/max(uResolution.y,1.0)*ref;
    float t = uPhase; // Existing audible-energy integral, not a new wall clock/BPM oscillator.
    float spd=100.0;
    float2 dir=float2(0.0,-1.0),perp=float2(1.0,0.0);
    float distort1=ferroNoise(p+perp*(t*spd),60.0,10.0)*50.0;
    float distort2=ferroNoise(p-perp*(t*spd),120.0,15.0)*100.0;
    float peaks=ferroDomainBlend(p+distort1+dir*(t*spd*0.5),40.0,1.0);
    float peaks2=ferroDomainBlend(p+distort2-dir*(t*spd*0.5),40.0,0.0);
    float mapeaks=ferroSmoothMin(peaks,peaks2,fluidity);
    // The already causal kick/spring opens the fluid rims. No new detector or fake beat.
    float punch=clamp(uImpact,0.0,1.0);
    float deformation=clamp(uSpringDeform,-0.15,0.15)*0.08;
    float rimWidth=0.20+punch*0.055;
    float band=(rimWidth-abs((mapeaks-0.4+deformation)*2.0))*5.0;
    float ltn=clamp(band-ferroNoise(p+dir*(t*spd*0.5),60.0,12.0)*shimmer,0.0,1.0);
    ltn=pow(ltn,sharpness)*glow;
    float h=clamp(0.5+(peaks-peaks2)*0.8,0.0,1.0);
    float3 col=ferroPalette(h,u)*ltn;
    col*=1.0+clamp(uLowEnergy,0.0,1.0)*0.20+punch*0.25;
    // Bright rims breathe; the dark field stays dark (no fullscreen flash or added blur).
    float hotspot=smoothstep(0.18,1.10,ltn);
    col*=1.0+hotspot*ferroLightPulse(u)*0.85;
    // Hue-preserving SDR compression; extended highlights handled by the existing output stage.
    col/=1.0+max(col.r,max(col.g,col.b))*0.35;

    float fX=max(0.04,0.14*uEdgeFeather);
    float fYTop = 0.015; // Fill behind Dynamic Island, keep original top/lower boundaries.
    float fYBot = max(0.03, 0.12 * uEdgeFeather);
    float featherX = smoothstep(0.0,fX,uvSample.x)*(1.0-smoothstep(1.0-fX,1.0,uvSample.x));
    float featherY = smoothstep(0.0, fYBot, uvSample.y)*(1.0-smoothstep(1.0 - fYTop, 1.0, uvSample.y));
    float cover=clamp(ltn*1.5,0.0,1.0)*featherX*featherY
                *mix(0.75,1.0,uDarkMode)*(0.86+clamp(uEnergy,0.0,1.0)*0.14);
    return float4(col,cover);
}

float3 linearP3(float3 srgb) {
  float3 linear=select(pow((srgb+0.055)/1.055,float3(2.4)),srgb/12.92,srgb<=float3(0.04045));
  // Linear sRGB -> linear Display P3; artwork hue is preserved, not oversaturated.
  return float3x3(float3(0.822593,0.033200,0.017085),
                 float3(0.177534,0.966783,0.072396),
                 float3(0.0,0.0,0.910302))*linear;
}

fragment float4 beatWaveField(BeatWaveVertex in [[stage_in]], constant BeatWaveUniforms &u [[buffer(0)]]) {
    float4 field = evalFerrofluid(clamp(in.uv,0.0,1.0),u);
    float alpha = clamp(field.a,0.0,1.0);
    float3 rgb=max(field.rgb,0.0);
    // A shared scale preserves artwork hue instead of clipping RGB channels separately.
    float sdrPeak=max(rgb.r,max(rgb.g,rgb.b));
    rgb*=sdrPeak>0.00001 ? (1.0-exp(-sdrPeak*1.25))/sdrPeak : 1.25;
    if (u.display.y>0.5) {
        float peak=max(rgb.r,max(rgb.g,rgb.b));
        float musicalHeadroom=0.35+ferroLightPulse(u)*0.65;
        float gain=1.0+(max(1.0,u.display.x)-1.0)*smoothstep(0.45,0.9,peak)*musicalHeadroom;
        rgb=linearP3(rgb)*gain; // Real >1 linear values for rgba16Float, not an SDR brightness label.
        rgb=clamp(rgb,0.0,max(1.0,u.display.x));
    }
    return float4(rgb * alpha,alpha); // Premultiplied alpha, directly to transparent drawable.
}
