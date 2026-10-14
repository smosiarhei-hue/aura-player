# Sonivo native icon validation

This is an isolated Icon Composer candidate. It does not replace the app's existing AppIcon.appiconset or change project.yml.

The two original wordmark outlines share a 1024×1024 canvas and one Combined Liquid Glass group. The background is a native solid fill. Shadows and specular highlights are native group settings, not painted into the SVG files.

The Validate Native App Icon workflow runs Apple's actool and ictool on macOS and publishes compiled resources, logs and default/dark previews. A missing Apple tool, asset compilation error or rendering error fails validation; a flat fallback is never presented as a native preview.

The manifest was constructed from observed Icon Composer files. It must pass native validation before production integration. CI rendering does not prove Home Screen appearance on a physical iPhone, including dynamic lighting, accessibility modes or small-size readability.

The illustrative approved preview is not a native render. Commercial redistribution rights for the source lettering have not been verified and require review before release.
