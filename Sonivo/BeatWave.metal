// Native port of the owner-supplied Beat Waves ZIP. See docs/beatwaves-native-handoff.md.
// Visualization only: no glass plate, rim, refraction, shadow or optical second pass.
#include <metal_stdlib>
using namespace metal;
struct BeatWaveUniforms {
    float4 resolution; // xy physical pixel size; zw reserved
    float4 motion; // phase, energy, impact, detail
    float4 surface; // spring displacement, dark mode, octave count, reserved
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
#define uColorA float3(1.0,0.15,0.55)
#define uColorB float3(0.58,0.20,0.95)
#define uColorC float3(0.10,0.85,0.98)
#define uEdgeFeather 1.0
#define uOpacity 1.0
#define uStrands 14.0
#define uStrandDrift 6.0
#define uStrandWidth 1.0
#define uHaloWidth 1.2
#define uHaloStrength 0.65
#define uZoom 1.0
#define uSpin 0.0
#define uTurbulence 0.16
#define uTurbulenceScale 4.0
#define uWarp 0.06
#define uPulse 18.0
#define uPulseSpeed 2.4
#define uSegment 6.0
#define uSegmentSpeed 1.2
#define uCore 1.25
#define uCoreFalloff 5.0
#define uArms 3.0
#define uSwirl 1.6
#define uChroma 0.007
#define uDrift float2(0.0)
#define uOctaves int(u.surface.z)
#define uHdrLuster 1.35
constant float TURN = 6.28318530718;
constant float HALF_TURN = 3.14159265359;
constant float LATTICE = 0.0078125;
constant float3 lumVec = float3(0.213, 0.715, 0.072);

// ==========================================
// ==========================================

float grain(float2 p, constant BeatWaveUniforms &u, texture2d<float> noise) {
  return noise.sample(beatNoiseSampler, p * LATTICE).r;
}

float turbulence(float2 p, constant BeatWaveUniforms &u, texture2d<float> noise) {
  float sum = 0.0;
  float span = 0.0;
  float gain = 0.5;
  for (int i = 0; i < 5; i++) {
    if (i >= uOctaves) break;
    sum += gain * grain(p, u, noise);
    span += gain;
    p += p;
    gain *= 0.5;
  }
  return sum / max(span, 0.0001);
}

float3 neuralTint(float t, constant BeatWaveUniforms &u, texture2d<float> noise) {
  float blend = sin(t * HALF_TURN * 0.5) * 0.5 + 0.5;
  float shade = cos(t * TURN) * 0.5 + 0.5;
  float3 col = mix(uColorA, uColorB, blend);
  col = mix(col, uColorC, 0.28 * sin(t * 2.5) + 0.28);
  return col * (0.6 + 0.4 * shade);
}

float2 turn(float2 p, float angle) {
  float s = sin(angle);
  float c = cos(angle);
  return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

float3 neuralStrand(float2 p, float s, float c, float t, float split, float curTurbulence, float pulseBoost, float energyBoost, float sharedFlow, constant BeatWaveUniforms &u, texture2d<float> noise) {
  float2 q = float2(p.x * c - p.y * s, p.x * s + p.y * c);

  if (abs(q.y) > 0.34 + curTurbulence * 0.5 + split) return float3(0.0);

  // Smooth gate with musical timing
  float gate = smoothstep(
    0.08,
    0.58,
    sin(q.x * uSegment + t * uSegmentSpeed) * cos(t * 0.8 + q.y * 3.5)
  );
  if (gate <= 0.0) return float3(0.0);

  // Shared low-frequency flow + cheap directional ripple. No per-strand octave texture loop.
  q.y += ((sharedFlow-0.5)*0.65 + sin(q.x*6.0+t*0.4+q.y*2.0)*0.175)*curTurbulence;

  float3 reach = abs(q.y + float3(split * s, 0.0, -split * s));
  float3 rim = max(1.0 - reach * 3.0, 0.0);
  
  float strandW = max(1.0, 45.0 / max(uStrandWidth, 0.05));
  float haloW = max(1.0, 15.0 / max(uHaloWidth, 0.05));
  float haloStr = uHaloStrength * (1.0 + energyBoost * 0.55);

  // Traveling electrical pulse running along the neural strand
  float pulse = sin(q.x * uPulse + t * uPulseSpeed) * 0.5 + 0.5;
  
  // Beat sync: snappy transient punch on kick drum, smooth decay in between
  float sharpPulse = pow(pulse, mix(1.15, 0.40, pulseBoost));
  float pulseSpike = sharpPulse * (1.0 + pulseBoost * 1.85);

  // Visible traveling action potential packet running smoothly along the axon
  float packetPhase = fract(q.x * 0.30 + t * (uPulseSpeed * 0.35));
  float packet = exp(-pow(packetPhase - 0.5, 2.0) * 36.0) * (0.35 + pulseBoost * 1.5);

  float specularLuster = pow(pulse, 4.0) * (0.7 + pulseBoost * 1.6) * uHdrLuster;
  float spineCore = exp(-reach.y * strandW * 1.6) * (1.6 + specularLuster);
  float spineInner = exp(-reach.y * strandW * 0.5) * 0.85;
  float spineHalo = exp(-reach.y * haloW) * haloStr;

  float3 spine = (spineCore + spineInner + spineHalo) * rim * rim * (pulseSpike + packet) * gate;

  float3 glint = mix(float3(1.0), float3(0.88, 0.96, 1.0), split * 15.0) * specularLuster * exp(-reach.y * strandW * 2.2);

  return spine + glint;
}

float3 neuralWeave(float2 p, float t, float split, float curTurbulence, float pulseBoost, float energyBoost, float sharedFlow, constant BeatWaveUniforms &u, texture2d<float> noise, constant BeatWaveStrand *strands) {
  float3 sum = float3(0.0);
  for (int i = 0; i < 32; i++) {
    float index = float(i);
    float4 direction = strands[i].direction;
    if (direction.z <= 0.0) break;
    float s = direction.x, c = direction.y;
    float3 lit = neuralStrand(p, s, c, t + index, split, curTurbulence, pulseBoost, energyBoost, sharedFlow, u, noise)
      + neuralStrand(p, c, -s, t * 1.15 + index, split, curTurbulence, pulseBoost, energyBoost, sharedFlow, u, noise);
    sum += strands[i].pigment.rgb * lit;
  }
  return sum;
}

float4 evalNeuralFloat(float2 uvSample, constant BeatWaveUniforms &u, texture2d<float> noise, constant BeatWaveStrand *strands) {
  float aspect = clamp(uResolution.x / max(uResolution.y, 1.0), 0.35, 2.5);
  float2 p = (uvSample - 0.5) * float2(aspect, 1.0);
  p = turn(p, uSpin) / max(uZoom, 0.01);

  // Continuous audio-integrated flow; no extra slow time multiplier.
  float t = uPhase;
  float energyBoost = clamp(uEnergy, 0.0, 1.0);
  float pulseBoost = clamp(uImpact, 0.0, 1.0);
  float springImpulse = clamp(uSpringDeform, -1.5, 1.5);

  float curTurbulence = uTurbulence * (1.0 + energyBoost * 0.45 + abs(springImpulse) * 0.18);

  // Kick moves the FIELD, never the cover or text. Immediate punch plus damped recoil.
  float radialPush = clamp(pulseBoost*0.08 + springImpulse*1.8,-0.12,0.24);
  p /= 1.0+radialPush;
  p.y += springImpulse*0.22*sin(p.x*8.0-t*0.9);
  // Only one octave-noise evaluation per pixel, reused by every strand.
  float sharedFlow = turbulence(p*2.0+t,u,noise);
  p += sharedFlow * (uWarp * (1.0 + energyBoost * 0.3));
  p -= uDrift * 0.15;

  float split = uChroma * (1.0 + 0.66 * sin(t * 0.4));
  float3 col = neuralWeave(p, t, split, curTurbulence, pulseBoost, energyBoost, sharedFlow, u, noise, strands);

  // Synaptic Plasma Core (pulsing smoothly on kick drums and sub-bass)
  float reach = length(p);
  float swirl = sin(atan2(p.y, p.x) * uArms + t * uSwirl);
  float coreEnergy = uCore * (1.0 + pulseBoost * 1.5 + max(0.0, springImpulse) * 0.8 + energyBoost * 0.4);
  col += neuralTint(t * 0.08, u, noise) * exp(-reach * uCoreFalloff) * (0.7 + 0.3 * swirl) * coreEnergy;

  // Smoothly compresses high dynamic range while lifting silky specular brilliance
  float3 hdrCol = col;
  float3 tonemapped = hdrCol / (float3(1.0) + hdrCol * 0.45);
  float3 peakLuster = pow(max(hdrCol - float3(0.60), float3(0.0)), float3(2.0)) * (0.75 * uHdrLuster);
  col = tonemapped + peakLuster;

  // Soft field fadeout
  col *= 1.0 - smoothstep(0.35, 1.35, reach);

  // Edge feathering to blend seamlessly with UI container
  float fX = max(0.04, 0.14 * uEdgeFeather);
  float fYTop = max(0.03, 0.12 * uEdgeFeather);
  float fYBot = max(0.05, 0.18 * uEdgeFeather);
  float featherX = smoothstep(0.0, fX, uvSample.x) * (1.0 - smoothstep(1.0 - fX, 1.0, uvSample.x));
  float featherY = smoothstep(0.0, fYTop, uvSample.y) * (1.0 - smoothstep(1.0 - fYBot, 1.0, uvSample.y));

  col = pow(max(col, 0.0), float3(0.92)) * 1.05;
  // Balanced baseline presence so deep sub-bass is always visibly clean and alluring
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
    float3 rgb = clamp(field.rgb,0.0,1.0);
    return float4(rgb * alpha,alpha); // Premultiplied alpha, directly to transparent drawable.
}
