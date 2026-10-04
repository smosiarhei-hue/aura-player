# Sonivo app icon — future iOS concept

Figma file: https://www.figma.com/design/GeukhtCXYmUVFuHJdToB3O

## Concept

The mark combines:

- an uninterrupted **S-shaped audio wave** for Sonivo;
- four center bars representing live playback and equalization;
- a crimson-to-violet-to-cobalt spectrum that stays recognizable without text;
- an opaque, edge-to-edge canvas so the system owns masking and corner treatment.

The icon intentionally contains no wordmark, subtitle, baked rounded rectangle, fake device
frame, or tiny decorative text.

## Appearance set

| Appearance | Source | Xcode asset |
| --- | --- | --- |
| Default | `design/app-icon/sonivo-icon.svg` | `AppIcon1024.png` |
| Dark | `design/app-icon/sonivo-icon-dark.svg` | `AppIcon1024-dark.png` |
| Tinted | `design/app-icon/sonivo-icon-tinted.svg` | `AppIcon1024-tinted.png` |

All PNGs are 1024×1024, fully opaque, and use the same silhouette across appearances.

## Apple guidance applied

- Keep the core visual features consistent across default, dark, clear, and tinted appearances.
- Let the system apply the final mask instead of drawing rounded corners into the artwork.
- Prefer a simple, recognizable symbol that remains legible at notification and Spotlight sizes.
- Keep important geometry away from the extreme edges.
- Use Icon Composer later if the final iOS 27 toolchain provides additional Liquid Glass layer controls.

References:

- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://developer.apple.com/icon-composer
- https://developer.apple.com/videos/play/wwdc2025/220/

## Figma structure

Import each SVG as a separate 1024×1024 frame named `Default`, `Dark`, and `Tinted`.
Keep the background, ambient rings, S-wave, highlight, and equalizer bars as separate layer
groups when preparing an Icon Composer export.

## Rollback

The previous icon remains available on
`backup/modern-my-wave-home-before-full-refactor` and can also be restored by reverting
the dedicated icon commit.
