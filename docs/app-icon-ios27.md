# Sonivo app icon

## Approved direction

The production mark uses two independent music-flow shapes separated by real negative space:

- **Upper Flow:** coral `#FF6B70` to magenta `#F2389D`.
- **Lower Flow:** violet `#9A48FF` through blue `#3978FF` to cyan `#27C7F7`.
- **Background:** an opaque graphite radial gradient from `#121522` to `#090A10`.

There is no wordmark, baked corner mask, glow, bevel, drop shadow, or simulated Liquid Glass.
The system owns the final icon mask and appearance treatment.

## Source files

Editable 1024×1024 SVG layers live in `design/app-icon/source/`:

- `Sonivo_Background.svg`
- `Sonivo_UpperFlow.svg`
- `Sonivo_LowerFlow.svg`
- `Sonivo_Mono_UpperFlow.svg`
- `Sonivo_Mono_LowerFlow.svg`

Review composites:

- `design/app-icon/sonivo-icon.svg`
- `design/app-icon/sonivo-icon-dark.svg`
- `design/app-icon/sonivo-icon-tinted.svg`

All files use the same `0 0 1024 1024` view box, so layers remain aligned when imported into Photoshop or Apple Icon Composer.

## Xcode appearances

| Appearance | Asset |
| --- | --- |
| Default | `AppIcon1024.png` |
| Dark | `AppIcon1024-dark.png` |
| Tinted | `AppIcon1024-tinted.png` |

The PNGs are opaque 1024×1024 RGB files. Their reviewable base64 payloads live in `design/app-icon/generated/` and a pre-build step materializes them before asset compilation. The default and dark appearances intentionally share the approved chromatic artwork. The tinted appearance uses the matching white/light-gray monochrome geometry.

## Icon Composer

Import the source layers without pre-masking them:

1. Background
2. Upper Flow
3. Lower Flow

Use the mono flow sources for the Clear/Mono appearance. Apply refraction, translucency, shadow, and specular treatment in Icon Composer rather than baking those effects into the source artwork.

## Rollback

The icon change is isolated in a dedicated commit. Reverting that commit restores the previous asset catalog artwork and sources.
