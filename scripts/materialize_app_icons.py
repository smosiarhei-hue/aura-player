#!/usr/bin/env python3
"""Materialize opaque app-icon PNGs from reviewable repository payloads."""
from __future__ import annotations
import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design" / "app-icon" / "generated"
DESTINATION = ROOT / "Sonivo" / "assets.xcassets" / "AppIcon.appiconset"


def main() -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name in ("AppIcon1024.png", "AppIcon1024-dark.png", "AppIcon1024-tinted.png"):
        encoded = (SOURCE / f"{name}.b64").read_text(encoding="ascii").strip()
        (DESTINATION / name).write_bytes(base64.b64decode(encoded, validate=True))

    ring_source = ROOT / "design" / "resonance" / "generated" / "ResonanceRingMask.png.b64"
    ring_destination = ROOT / "Sonivo" / "assets.xcassets" / "ResonanceRingMask.imageset"
    ring_destination.mkdir(parents=True, exist_ok=True)
    (ring_destination / "ResonanceRingMask.png").write_bytes(
        base64.b64decode(ring_source.read_text(encoding="ascii").strip(), validate=True)
    )

    launch_source = ROOT / "design" / "resonance" / "generated" / "ResonanceLaunchLogo.png.b64"
    launch_destination = ROOT / "Sonivo" / "assets.xcassets" / "ResonanceLaunchLogo.imageset"
    launch_destination.mkdir(parents=True, exist_ok=True)
    (launch_destination / "ResonanceLaunchLogo.png").write_bytes(
        base64.b64decode(launch_source.read_text(encoding="ascii").strip(), validate=True)
    )


if __name__ == "__main__":
    main()
