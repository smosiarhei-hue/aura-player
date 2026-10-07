// Native port of the owner-supplied Beat Waves ZIP. See docs/beatwaves-native-handoff.md.
// Visualization only: no glass plate, rim, refraction, shadow or optical second pass.
#include <metal_stdlib>
using namespace metal;
struct BeatWaveUniforms {
    float4 resolution; // xy physical pixel size; zw reserved
    float4 motion; // phase, energy, impact, detail
    float4 surface; // spring displacement, dark mode, octave count, bass envelope
    float4 colorA;
    float4 colorB;
    float4 colorC;
    float4 display; // current EDR headroom, linear-P3 output flag, reserved
};
struct BeatWaveStrand { float4 direction; float4 pigment; };
struct BeatWaveVertex { float4 position [[position]]; float2 uv; };
vertex BeatWaveVertex beatWaveVertex(uint id [[vertex_id]]) {
    float2 p = id == 0 ? float2(-1,-1) : (id == 1 ? float2(3,-1) : float2(-1,3));
    return {float4(p,0,1), (p+1)*0.5};
}
constexpr sampler beatNoiseSampler(coord::normalized, address::repeat, filter::linear);
#define uResolution u.resolution.xy
#define uPhase u.motion.x
#define uEnergy u.motion.y
#define uImpact u.motion.z
#define uDetail u.motion.w
#define uSpringDeform u.surface.x
#define uDarkMode u.surface.y
#define uColorA u.colorA.rgb
#define uColorB u.colorB.rgb
#define uColorC u.colorC.rgb
#define uEdgeFeather 1.0
#define uOpacity 1.0
#define uTurbulence 0.16
#define uHaloStrength 0.65
#define uOctaves int(u.surface.z)
#define uLowEnergy u.surface.w
constant float TURN = 6.28318530718;
constant float HALF_TURN = 3.14159265359;
constant float LATTICE = 0.0078125;
constant float3 lumVec = float3(0.213, 0.715, 0.072);

// ==========================================
// ==========================================

// The archive's octave function precomputed in RGB. One sample instead of 3 per strand.
float turbulence(float2 p,constant BeatWaveUniforms &u,texture2d<float> noise) {
  float3 packed=noise.sample(beatNoiseSampler,p*LATTICE).rgb;
  return uOctaves>=3 ? packed.r : (uOctaves==2 ? packed.g : packed.b);
}

// Owner-supplied Neural Float weave: paired axes, segmented filaments, bright spine and halo.
// Fixed axes and musical phase preserve no orbit/no fabricated beat. Archive per-strand noise is restored.
float3 neuralStrand(float2 p, float s, float c, float bendPhase, float strandID,
                   constant BeatWaveUniforms &u,texture2d<float> noise) {
  float2 q = float2(p.x*c-p.y*s,p.x*s+p.y*c);
  float split=0.006;
  float curTurbulence=0.15*(1.0+uLowEnergy*0.35);
  if (abs(q.y)>0.34+curTurbulence*0.5+split) return float3(0.0);
  // Archive segment carrier follows the slow MUSIC-integrated phase, not wall time.
  float t=bendPhase+strandID;
  float gate=smoothstep(0.08,0.58,sin(q.x*6.0+t*1.2)*cos(t*0.8+q.y*3.5));
  if (gate<=0.0) return float3(0.0);
  q.y+=(turbulence(q*4.0+t*0.4,u,noise)-0.5)*curTurbulence;
  q.y+=(uSpringDeform*0.8+uImpact*0.02)*sin(q.x*8.0+strandID);
  float3 reach=abs(q.y+float3(split*s,0.0,-split*s));
  float3 rim=max(1.0-reach*3.0,0.0);
  float pulse=sin(q.x*18.0+t*2.4)*0.5+0.5;
  float shaped=pow(pulse,mix(1.15,0.55,uImpact));
  float musicalLight=0.42+uLowEnergy*0.55+uImpact*0.65;
  float specularLuster=pow(pulse,4.0)*(0.25+uImpact*0.75);
  float spineCore=exp(-reach.y*45.0*1.6)*(1.6+specularLuster);
  float spineInner=exp(-reach.y*45.0*0.5)*0.85;
  float spineHalo=exp(-reach.y*15.0)*0.5*(1.0+uLowEnergy*0.55);
  return (spineCore+spineInner+spineHalo)*rim*rim*(0.30+shaped)*gate*musicalLight;
}

float3 neuralWeave(float2 p,float t,texture2d<float> noise,constant BeatWaveUniforms &u,
                  constant BeatWaveStrand *strands) {
  float3 sum=float3(0.0);
  for (int i = 0; i < 32; i++) {
    float4 direction=strands[i].direction;
    if (direction.z<=0.0) break;
    float3 lit=neuralStrand(p,direction.x,direction.y,t,direction.w,u,noise)
      +neuralStrand(p,direction.y,-direction.x,t*1.15,direction.w,u,noise);
    sum+=strands[i].pigment.rgb*lit;
  }
  return sum*0.30;
}

float3 linearP3(float3 srgb) {
  float3 linear=select(pow((srgb+0.055)/1.055,float3(2.4)),srgb/12.92,srgb<=float3(0.04045));
  // Linear sRGB -> linear Display P3; artwork hue is preserved, not oversaturated.
  return float3x3(float3(0.822593,0.033200,0.017085),
                 float3(0.177534,0.966783,0.072396),
                 float3(0.0,0.0,0.910302))*linear;
}

float4 evalNeuralFloat(float2 uvSample, constant BeatWaveUniforms &u, texture2d<float> noise, constant BeatWaveStrand *strands) {
  float aspect = clamp(uResolution.x / max(uResolution.y, 1.0), 0.35, 2.5);
  float2 p = (uvSample - 0.5) * float2(aspect, 1.0);
  float t = uPhase;
  float energyBoost = clamp(uEnergy,0.0,1.0);
  // Archive whole-field warp plus EACH strand's own curved turbulence.
  p+=turbulence(p*2.0+t,u,noise)*0.06*(1.0+energyBoost*0.3);
  float3 col = neuralWeave(p,t,noise,u,strands);
  float reach = length(p);
  // Stationary soft core. No angular/time term and no independent brightness pulsation.
  float coreEnergy = 0.08+uLowEnergy*0.08+uImpact*0.08;
  col += mix(uColorA,uColorB,0.5)*exp(-reach*5.0)*coreEnergy;

  // Hue-preserving SDR base. EDR highlight extension happens only in the final output stage.
  float peak=max(col.r,max(col.g,col.b));
  col/=1.0+peak;
  // Preserve a visible kick after tone compression; no white glint/bloom second pass.
  col*=0.78+uLowEnergy*0.18+uImpact*0.24;

  // Soft field fadeout
  col *= 1.0 - smoothstep(0.35, 1.35, reach);

  // Edge feathering to blend seamlessly with UI container
  float fX = max(0.04, 0.14 * uEdgeFeather);
  float fYTop = 0.015; // Fill behind Dynamic Island; only the physical top edge fades.
  float fYBot = max(0.03, 0.12 * uEdgeFeather); // Original physical LOWER fade.
  float featherX = smoothstep(0.0, fX, uvSample.x) * (1.0 - smoothstep(1.0 - fX, 1.0, uvSample.x));
  // Metal clip +Y is screen TOP: this vertex shader maps it to uv.y=1.
  float featherY = smoothstep(0.0, fYBot, uvSample.y) * (1.0 - smoothstep(1.0 - fYTop, 1.0, uvSample.y));

  col = pow(max(col, 0.0), float3(0.92)) * 1.05;
  // Soft alpha feather, including the original lower boundary.
  float cover = clamp(max(col.r, max(col.g, col.b)) * 1.30, 0.0, 1.0)
    * featherX * featherY
    * mix(0.75, 1.0, uDarkMode)
    * (0.86 + energyBoost * 0.14)
    * uOpacity;

  return float4(col, cover);
}

fragment float4 beatWaveField(BeatWaveVertex in [[stage_in]], constant BeatWaveUniforms &u [[buffer(0)]], constant BeatWaveStrand *strands [[buffer(1)]], texture2d<float> noise [[texture(0)]]) {
    float4 field = evalNeuralFloat(clamp(in.uv,0.0,1.0),u,noise,strands);
    float alpha = clamp(field.a,0.0,1.0);
    float3 rgb=clamp(field.rgb,0.0,1.0);
    if (u.display.y>0.5) {
        float peak=max(rgb.r,max(rgb.g,rgb.b));
        float gain=1.0+(max(1.0,u.display.x)-1.0)*smoothstep(0.45,0.9,peak);
        rgb=linearP3(rgb)*gain; // Real >1 linear values for rgba16Float, not an SDR brightness label.
        rgb=clamp(rgb,0.0,max(1.0,u.display.x));
    }
    return float4(rgb * alpha,alpha); // Premultiplied alpha, directly to transparent drawable.
}
