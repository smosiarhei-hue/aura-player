# Sonivo Icon Composer candidates

`SonivoMusic.icon` is the current preview candidate: the original Sonivo S, an open rounded contour, and a five-bar waveform. `AppIcon.icon` retains the earlier full-wordmark candidate.

The S is transformed uniformly from the original outlined source, not redrawn. All three foreground layers share a 1024x1024 canvas and a Combined native glass group. The charcoal background is a native solid fill. SVG artwork has no painted reflections, shadows, blur, alpha effects or corner masking.

The macOS validation workflow compiles only the isolated candidate with Apple's actool and renders Default/Dark previews with the official Icon Composer ictool. It does not change project.yml or the app's production icon assets. No flat fallback is described as native.

CI rendering is not a physical iPhone Home Screen test. Validate dynamic lighting and small-size appearance on a device before release. Source-lettering redistribution rights require review before commercial distribution.
