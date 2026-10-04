#!/usr/bin/env python3
"""Materialize opaque PNG app-icon assets from reviewable repository payloads."""
from __future__ import annotations

import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design" / "app-icon" / "generated"
DESTINATION = ROOT / "Sonivo" / "assets.xcassets" / "AppIcon.appiconset"


def main() -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    names = ("AppIcon1024.png", "AppIcon1024-dark.png", "AppIcon1024-tinted.png")
    for name in names:
        encoded = (SOURCE / f"{name}.b64").read_text(encoding="ascii").strip()
        (DESTINATION / name).write_bytes(base64.b64decode(encoded, validate=True))


if __name__ == "__main__":
    main()
