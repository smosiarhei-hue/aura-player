#!/usr/bin/env python3
"""Decode the licensed, fixed-weight Onest font before Xcode copies its folder."""
import base64
import hashlib
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
EXPECTED_SHA256 = "063c1194c24eab5d9b547fedcaefed9a5f2e60ec2bb6c039b85963e4223f75a4"
def materialize(root: Path = ROOT) -> Path:
    source = root / "design/typography/Onest-Bold.ttf.b64"
    data = base64.b64decode(source.read_text(encoding="ascii").strip(), validate=True)
    if hashlib.sha256(data).hexdigest() != EXPECTED_SHA256:
        raise ValueError("Onest font payload checksum mismatch")
    if data[:4] != b"\x00\x01\x00\x00":
        raise ValueError("Onest font is not a TrueType sfnt")
    destination = root / "Sonivo/KaraokeFonts/Onest-Bold.ttf"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists() or destination.read_bytes() != data:
        destination.write_bytes(data)
    return destination
if __name__ == "__main__":
    materialize()
