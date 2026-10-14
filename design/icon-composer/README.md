# Sonivo Icon Composer candidates

`SonivoMusic.icon` is the current preview candidate: the original Sonivo S, an open rounded contour, and a five-bar waveform. `AppIcon.icon` retains the earlier full-wordmark candidate.

The S is transformed uniformly from the original outlined source, not redrawn. All three foreground layers share a 1024x1024 canvas and a Combined native group. The background is a native neutral near-black #161616 solid fill, selected from the supplied reference (JPEG samples varied approximately #151515–#1B1B1B). Foreground is opaque white; glass, specular and translucency are disabled to avoid a raised chrome-like symbol. Native platform background lighting/corner treatment still applies; this is not a guarantee of identical photographed Home Screen appearance. SVG artwork has no painted reflections, shadows, blur, alpha effects or corner masking.

The macOS validation workflow compiles only the isolated candidate with Apple's actool and renders Default/Dark previews with the official Icon Composer ictool. It does not change project.yml or the app's production icon assets. No flat fallback is described as native.

CI rendering is not a physical iPhone Home Screen test. Validate dynamic lighting and small-size appearance on a device before release. Source-lettering redistribution rights require review before commercial distribution.

## Production integration and settings

Four native documents are built from `Sonivo/AppIcons`: SonivoMusic (primary), SignatureS, SonivoWordmark, ClassicWave. All share the reference neutral #161616 background and opaque white foreground. Older coral sources remain preserved in design/app-icon; they are not the active primary icon.

Settings > Appearance > App icon uses UIApplication.setAlternateIconName, nil for primary. The OS owns persistence and confirmation. Success is shown only from the completion callback and actual alternateIconName. Unsupported installations and errors are visible. No launch-time icon reset occurs.

Settings thumbnail PNGs are flat artwork previews; system light, tint and native Home Screen depth are not baked into them. Native validation renders all four documents. IPA packaging validates generated CFBundleIcons registration before shipping.
