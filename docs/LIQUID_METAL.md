# Sonivo liquid-metal surfaces

Source: https://libraries.dev/metal — native SwiftUI MetalFxKit shader, not React or a WebView.
Pinned source: https://github.com/Jakubantalik/Libraries.dev/tree/bfcb86329da15235a5ee2dcdb6417c8a80f82bb1/packages/metal-fx/ports/ios/MetalFxKit

Only MetalFxShaders.metal is vendored. Exported stitchable function renamed to
sonivoLiquidMetal and input mapping adapted to SwiftUI boundingRect with an
inset UV window (so even wide cards retain the rim); material math is unchanged. Swift surface, lifecycle,
quality policy and integration are Sonivo code. No upstream 60-Hz TimelineView,
glow simulation, CoreMotion, reflection registry or mutable package dependency.
MIT MetalFxKit and Apache-2.0 Paper Shaders licenses ship in Resources/Licenses.
Shader includes the upstream Paper Shaders attribution (liquidMetal 0.0.80).

## Coverage
- Shared glassCard, glassCapsule, glassCircle, glassProminent: static specular rim.
- Thus shared home/library/catalog, chips, sheets and player icon controls inherit it.
- Player close, track-radio action and Play: same family. Artwork tint unchanged.
- Settings category icon tiles: static rim; existing labels/semantic accent intact.
- Only Play opts into 30-Hz rendering, and only while playing. Other surfaces have
  no timeline, display link, frame reporter, sensor or geometry observation.
- No change to track artwork, video, lyrics, long-list text, EQ DSP, music haptics,
  app icon resources, startup, search, transport actions or system Dynamic Island.
- OS-native glass remains the underlying surface; shader is a hit-test-free,
  accessibility-hidden narrow overlay, never an action replacement or text fill.

## Fallback
Appearance > Interface materials > Metal highlights disables it immediately.
Default on. The shader subtree (including clock) is removed for Reduce Motion,
Reduce Transparency, Increased Contrast, Low Power Mode, serious/critical thermal
state, inactive scene or disabled control. Native UI underneath is unchanged.
Thermal/power notifications and foreground transitions reevaluate eligibility.

## Validation
CI compiles the stitchable Metal shader and Swift in the signed iOS build.
Source-contract tests verify clock scope, fallbacks, shared integration and licenses.
These checks do not measure on-device GPU/battery cost or prove a device frame rate.
Device QA: light/dark + every accent; VoiceOver; low power/thermal transitions;
background/resume; Reduce Motion/Transparency/Increased Contrast; paused/loading
Play; rapid track switches; scrolling large libraries. No native screenshot is
claimed from a web mockup.
