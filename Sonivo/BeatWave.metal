// Native port of the owner-supplied Beat Waves ZIP. See docs/beatwaves-native-handoff.md.
// SDR luminous shader, not a Dolby Vision implementation. Two passes avoid repeated field evaluation.
#include <metal_stdlib>
using namespace metal;
struct BeatWaveUniforms {
    float4 resolution; // xy physical pixel size; zw reserved
    float4 motion; // phase, energy, impact, detail
    float4 surface; // spring displacement, dark mode, corner radius in pixels, reserved
};
struct BeatWaveVertex { float4 position [[position]]; float2 uv; };
vertex BeatWaveVertex beatWaveVertex(uint id [[vertex_id]]) {
    float2 p = id == 0 ? float2(-1,-1) : (id == 1 ? float2(3,-1) : float2(-1,3));
    return {float4(p,0,1), (p+1)*0.5};
}
constexpr sampler beatNoiseSampler(coord::normalized, address::repeat, filter::linear);
constexpr sampler beatSceneSampler(coord::normalized, address::clamp_to_edge, filter::linear);
#define uResolution u.resolution.xy
#define uPhase u.motion.x
#define uEnergy u.motion.y
#define uImpact u.motion.z
#define uDetail u.motion.w
#define uSpringDeform u.surface.x
#define uDarkMode u.surface.y
#define uGlassCornerRadius u.surface.z
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
#define uOctaves 3
#define uHdrLuster 1.35
#define uLiquidGlassEnabled 1.0
#define uGlassSaturation 1.45
#define uGlassRefractionHeight 0.20
#define uGlassRefractionAmount 0.16
#define uGlassDispersion 0.85
#define uGlassDepthEffect 0.45
#define uGlassHighlightAlpha 0.25
#define uGlassSpotRadius 90.0
#define uGlassDarkening 1.0
#define uGlassTintAlpha 0.10
#define uMousePos float2(0.5)
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

float3 neuralStrand(float2 p, float s, float c, float t, float split, float curTurbulence, float pulseBoost, float energyBoost, constant BeatWaveUniforms &u, texture2d<float> noise) {
  float2 q = float2(p.x * c - p.y * s, p.x * s + p.y * c);

  if (abs(q.y) > 0.34 + curTurbulence * 0.5 + split) return float3(0.0);

  // Smooth gate with musical timing
  float gate = smoothstep(
    0.08,
    0.58,
    sin(q.x * uSegment + t * uSegmentSpeed) * cos(t * 0.8 + q.y * 3.5)
  );
  if (gate <= 0.0) return float3(0.0);

  q.y += (turbulence(q * uTurbulenceScale + t * 0.4, u, noise) - 0.5) * curTurbulence;

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

float3 neuralWeave(float2 p, float t, float split, float curTurbulence, float pulseBoost, float energyBoost, constant BeatWaveUniforms &u, texture2d<float> noise) {
  float3 sum = float3(0.0);
  float count = max(uStrands + (uStrandDrift + energyBoost * 2.5) * sin(t * 0.3), 1.0);

  for (int i = 0; i < 32; i++) {
    float index = float(i);
    if (index > count) break;

    float fade = clamp(count - index, 0.0, 1.0);
    float id = index / count;
    float angle = id * TURN + t * 0.12;
    float s = sin(angle);
    float c = cos(angle);

    float3 lit = neuralStrand(p, s, c, t + index, split, curTurbulence, pulseBoost, energyBoost, u, noise)
      + neuralStrand(p, c, -s, t * 1.15 + index, split, curTurbulence, pulseBoost, energyBoost, u, noise);
    if (lit.r + lit.g + lit.b <= 0.0) continue;

    sum += neuralTint(id + t * 0.05, u, noise) * lit * (0.6 + 0.4 * sin(index * 3.0 + t)) * fade;
  }

  return sum;
}

float4 evalNeuralFloat(float2 uvSample, constant BeatWaveUniforms &u, texture2d<float> noise) {
  float aspect = clamp(uResolution.x / max(uResolution.y, 1.0), 0.35, 2.5);
  float2 p = (uvSample - 0.5) * float2(aspect, 1.0);
  p = turn(p, uSpin) / max(uZoom, 0.01);

  // Smooth, organic time flow (never rushing or racing)
  float t = uPhase * 0.6;
  float energyBoost = clamp(uEnergy, 0.0, 1.0);
  float pulseBoost = clamp(uImpact, 0.0, 1.0);
  float springImpulse = clamp(uSpringDeform, -1.5, 1.5);

  float curTurbulence = uTurbulence * (1.0 + energyBoost * 0.45 + abs(springImpulse) * 0.18);

  p += turbulence(p * 2.0 + t, u, noise) * (uWarp * (1.0 + energyBoost * 0.3));
  p -= uDrift * 0.15;

  float split = uChroma * (1.0 + 0.66 * sin(t * 0.4));
  float3 col = neuralWeave(p, t, split, curTurbulence, pulseBoost, energyBoost, u, noise);

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

// Unified Scene Evaluator (Neural Float)
float4 evalScene(float2 uvSample, constant BeatWaveUniforms &u, texture2d<float> noise) {
    return evalNeuralFloat(uvSample, u, noise);
}

// ==========================================
fragment float4 beatWaveField(BeatWaveVertex in [[stage_in]], constant BeatWaveUniforms &u [[buffer(0)]], texture2d<float> noise [[texture(0)]]) {
    return evalNeuralFloat(clamp(in.uv,0.0,1.0),u,noise);
}
float4 beatWaveSample(texture2d<float> scene, float2 uv) {
    return scene.sample(beatSceneSampler, float2(uv.x, 1.0-uv.y));
}
float sdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    float outside = length(max(cornerCoord, 0.0)) - radius;
    float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
    return outside + inside;
}

float2 gradSdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    float2 s = float2(coord.x >= 0.0 ? 1.0 : -1.0, coord.y >= 0.0 ? 1.0 : -1.0);
    if (cornerCoord.x > 0.0 || cornerCoord.y > 0.0) {
        float2 c = max(cornerCoord, 0.0);
        float len = length(c);
        if (len > 0.0)
            return s * (c / len);
    }
    float gradX = step(cornerCoord.y, cornerCoord.x);
    return s * float2(gradX, 1.0 - gradX);
}

float circleMap(float x) {
    return 1.0 - sqrt(max(0.0, 1.0 - x * x));
}

fragment float4 beatWaveGlass(BeatWaveVertex in [[stage_in]], constant BeatWaveUniforms &u [[buffer(0)]], texture2d<float> scene [[texture(0)]]) {
    float2 uv = clamp(in.uv, 0.0, 1.0);

    // Base background color (Neural Float)
    float4 baseScene = beatWaveSample(scene, uv);

    if (uLiquidGlassEnabled < 0.5) {
        // Direct background rendering without glass plate
        return float4(baseScene.rgb * baseScene.a, baseScene.a);

    }

    // --- WindowsLiquidGlass Optics Model ---
    // Glass card centered in viewport
    float2 glassCenter = float2(0.5, 0.5);
    float2 glassHalfSize = float2(0.44, 0.44); // 88% width and height card
    float2 coord = uv - glassCenter;
    
    float radius = clamp(uGlassCornerRadius / max(uResolution.y, 1.0), 0.02, min(glassHalfSize.x, glassHalfSize.y) * 0.9);
    float sd = sdRoundedRect(coord, glassHalfSize, radius);

    // SDF Soft Drop Shadow
    float2 shadowOffset = float2(0.0, -0.015);
    float shadowSd = sdRoundedRect(coord + shadowOffset, glassHalfSize, radius);
    float shadowAlpha = (1.0 - smoothstep(0.0, 0.06, shadowSd)) * 0.35 * (1.0 - smoothstep(-0.02, 0.0, sd));

    // Outside glass: render base scene with drop shadow
    if (sd > 0.002) {
        float3 finalBg = baseScene.rgb;
        float finalAlpha = max(baseScene.a, shadowAlpha);
        if (shadowAlpha > 0.001) {
            finalBg = mix(finalBg, float3(0.0), shadowAlpha * 0.5);
        }
        return float4(finalBg * finalAlpha, finalAlpha);

    }

    // Inside Liquid Glass:
    // 1. Refraction calculation with circleMap
    float refrHeight = max(0.01, uGlassRefractionHeight * 0.5);
    float t = clamp(1.0 - (-sd / refrHeight), 0.0, 1.0);
    float d = circleMap(t) * uGlassRefractionAmount * 0.25;

    // Refraction normal gradient
    float gr = min(radius * 1.5, min(glassHalfSize.x, glassHalfSize.y));
    float2 ccN = coord / (length(coord) + 1e-6);
    float2 grad = normalize(gradSdRoundedRect(coord, glassHalfSize, gr) + uGlassDepthEffect * ccN);

    // Refracted coordinate
    float2 ruv = uv + d * grad;

    float dispFactor = (coord.x * coord.y) / (glassHalfSize.x * glassHalfSize.y);
    float2 doff = d * grad * dispFactor * uGlassDispersion * 1.5;

    float4 colorAcc = float4(0.0);
    float4 s;

    // 7-sample weighted spectral accumulation of underlying scene
    s = beatWaveSample(scene, ruv + doff);                   colorAcc.r += s.r / 3.5; colorAcc.a += s.a / 7.0;
    s = beatWaveSample(scene, ruv + doff * (2.0 / 3.0));      colorAcc.r += s.r / 3.5; colorAcc.g += s.g / 7.0; colorAcc.a += s.a / 7.0;
    s = beatWaveSample(scene, ruv + doff * (1.0 / 3.0));      colorAcc.r += s.r / 3.5; colorAcc.g += s.g / 3.5; colorAcc.a += s.a / 7.0;
    s = beatWaveSample(scene, ruv);                           colorAcc.g += s.g / 3.5; colorAcc.a += s.a / 7.0;
    s = beatWaveSample(scene, ruv - doff * (1.0 / 3.0));      colorAcc.g += s.g / 3.5; colorAcc.b += s.b / 3.0; colorAcc.a += s.a / 7.0;
    s = beatWaveSample(scene, ruv - doff * (2.0 / 3.0));      colorAcc.b += s.b / 3.0; colorAcc.a += s.a / 7.0;
    s = beatWaveSample(scene, ruv - doff);                   colorAcc.r += s.r / 7.0; colorAcc.b += s.b / 3.0; colorAcc.a += s.a / 7.0;

    float lum = dot(colorAcc.rgb, lumVec);
    float3 saturated = mix(float3(lum), colorAcc.rgb, uGlassSaturation);
    saturated = clamp(saturated * uGlassDarkening, 0.0, 1.0);

    // 4. Subtle frosted glass tint
    float3 glassTint = mix(float3(0.95, 0.98, 1.0), float3(0.10, 0.14, 0.22), uDarkMode);
    float3 tinted = mix(saturated, glassTint, uGlassTintAlpha);

    float mouseAspect = clamp(uResolution.x / max(uResolution.y, 1.0), 0.35, 2.5);
    float2 mouseDelta = (uv - uMousePos) * float2(mouseAspect, 1.0);
    float mouseDist = length(mouseDelta);
    float spotNormRadius = uGlassSpotRadius / max(uResolution.y, 1.0);
    float spotIntensity = (1.0 - smoothstep(0.0, spotNormRadius, mouseDist)) * uGlassHighlightAlpha;

    // 6. Specular Edge Rim Light (crystal beveled border reflection)
    float rimBevel = smoothstep(-0.012, -0.001, sd) * (1.0 - smoothstep(-0.001, 0.002, sd));
    float3 rimColor = mix(float3(1.0, 1.0, 1.0), uColorC, 0.4);

    float3 finalGlassRgb = tinted + float3(spotIntensity) * 0.8 + rimColor * rimBevel * 0.7;

    // Edge anti-aliasing
    float edgeAA = 1.0 - smoothstep(-0.003, 0.001, sd);
    float finalAlpha = clamp(colorAcc.a * 1.15 + 0.18 + spotIntensity * 0.3, 0.25, 0.95) * edgeAA;

    return float4(finalGlassRgb * finalAlpha, finalAlpha);
}
