#!/usr/bin/env python3
"""Fail packaging when iOS has not registered the shipped alternate icons."""
import plistlib
import sys
from pathlib import Path

def verify(app: Path) -> None:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    icons = info.get("CFBundleIcons", {})
    primary = icons.get("CFBundlePrimaryIcon", {})
    assert primary.get("CFBundleIconName") == "SonivoMusic", primary
    alternates = icons.get("CFBundleAlternateIcons", {})
    expected = {"SignatureS", "SonivoWordmark", "ClassicWave", "MusicGraphite", "MusicPrism", "MusicSapphire", "MusicNeon"}
    assert expected <= set(alternates), f"Missing alternates: {expected - set(alternates)}"
    for name in expected:
        assert alternates[name].get("CFBundleIconName") == name, alternates[name]
    assert (app / "Assets.car").is_file(), "Missing compiled asset catalog"
    print("Icon bundle validated: SonivoMusic + SignatureS, SonivoWordmark, ClassicWave.")

if __name__ == "__main__":
    verify(Path(sys.argv[1]))