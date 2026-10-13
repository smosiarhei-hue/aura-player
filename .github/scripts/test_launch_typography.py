"""Portable brand asset and material/skill installation guards; no font package dependency."""
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LaunchTypographyTests(unittest.TestCase):
    def test_embedded_brand_font_is_pinned_valid_and_offline(self):
        source = (ROOT / "Sonivo/SonivoLaunchTypography.swift").read_text()
        encoded = re.search(r'fontBase64 = """\s*(.*?)\s*"""', source, re.S).group(1)
        data = base64.b64decode("".join(encoded.split()), validate=True)
        provenance = json.loads((ROOT / "docs/launch-font-provenance.json").read_text())
        self.assertEqual(hashlib.sha256(data).hexdigest(), provenance["derived_sha256"])
        self.assertEqual(data[:4], b"\x00\x01\x00\x00")
        count = struct.unpack_from(">H", data, 4)[0]
        tables = {}
        for index in range(count):
            tag, _, offset, length = struct.unpack_from(">4sIII", data, 12 + index * 16)
            self.assertLessEqual(offset + length, len(data))
            tables[tag] = data[offset:offset + length]
        for required in [b"cmap", b"glyf", b"head", b"maxp", b"name"]:
            self.assertIn(required, tables)
        self.assertNotIn(b"fvar", tables)  # static 800 cut, not a per-frame variation mutation
        self.assertGreater(struct.unpack_from(">H", tables[b"maxp"], 4)[0], 6)
        self.assertIn("SonivoResonanceSerif".encode("utf-16-be"), tables[b"name"])
        self.assertIn("SIL OPEN FONT LICENSE", (ROOT / "ThirdPartyNotices/InstrumentSerif-OFL.txt").read_text())
        self.assertIn("guard !didPrepare", source)
        self.assertIn("CTFontManagerRegisterGraphicsFont(font, nil)", source)
        self.assertNotIn("URLSession", source)

    def test_font_registration_happens_before_the_shared_animation_clock(self):
        source = (ROOT / "Sonivo/SonivoLaunchIntro.swift").read_text()
        register = source.index("brandFontName = SonivoLaunchTypography.prepare()")
        self.assertLess(source.index("RootView(onExternalPlaybackOpen: finish)"), register)
        self.assertLess(source.index("session.begin("), register)
        self.assertLess(register, source.index("epoch = haptics.start"))
        scene = source[source.index("private struct SonivoLaunchIntro"):source.index("/// Dedicated")]
        self.assertNotIn("prepare()", scene)
        word = (ROOT / "Sonivo/SonivoLaunchWordmark.swift").read_text()
        self.assertIn("Font.custom($0, fixedSize: 65 * unit)", word)
        self.assertIn("design: .serif", word)

    def test_new_scene_is_native_ring_not_chrome_or_true_focus(self):
        source = (ROOT / "Sonivo/SonivoLaunchIntro.swift").read_text()
        symbol = (ROOT / "Sonivo/SonivoResonanceSymbol.swift").read_text()
        for removed in ["sonivoLaunchChrome", "focusedWord", "SonivoLaunchFocusBounds"]:
            self.assertNotIn(removed, source)
        self.assertIn("SonivoLaunchWordmark(time: time", source)
        self.assertIn('Image("ResonanceLaunchLogo")', symbol)
        self.assertIn("sonivoLaunchRadialExposure", symbol)
        self.assertIn("reduceMotion ? 1 : SonivoLaunchMotion.ringOpacity", symbol)
        self.assertIn(".accessibilityHidden(true)", symbol)

    def test_atmosphere_uses_native_transforms_and_no_separate_clock(self):
        source = (ROOT / "Sonivo/SonivoLaunchAtmosphere.swift").read_text()
        self.assertEqual(source.count("RadialGradient("), 2)
        self.assertIn("reduced ? 0 : SonivoLaunchMotion.atmosphereDrift", source)
        self.assertIn("increasedContrast || reduceTransparency ? 0 : 1", source)
        self.assertIn(".offset(", source)
        for forbidden in ["TimelineView", "Timer.", "Canvas", "drawingGroup", "Date(", "ShaderLibrary"]:
            self.assertNotIn(forbidden, source)
        self.assertIn(".allowsHitTesting(false)", source)
        self.assertIn(".accessibilityHidden(true)", source)

    def test_skills_are_version_pinned_and_not_native_dependencies(self):
        lock = json.loads((ROOT / "agent_skills/motion-skills.lock.json").read_text())
        repositories = {package["repository"] for package in lock["packages"]}
        self.assertEqual(repositories, {"heygen-com/hyperframes", "emilkowalski/skills",
                                       "twostraws/SwiftUI-Agent-Skill"})
        for package in lock["packages"]:
            self.assertRegex(package["commit"], r"^[a-f0-9]{40}$")
            self.assertRegex(package["archive_sha256"], r"^[a-f0-9]{64}$")
            self.assertTrue(package["files"])
            for item in package["files"]:
                self.assertNotIn("..", Path(item["path"]).parts)
                self.assertFalse(Path(item["path"]).is_absolute())
                self.assertRegex(item["sha256"], r"^[a-f0-9]{64}$")
            notice = ROOT / ".agents/vendor-notices" / package["repository"].replace("/", "--")
            self.assertTrue(any(p.name.upper().startswith("LICENSE") for p in notice.iterdir()))
        installer = (ROOT / "scripts/install_motion_skills.py").read_text()
        self.assertIn('package["archive_sha256"]', installer)
        self.assertIn("seen != set(expected)", installer)
        self.assertNotIn("subprocess", installer)
        project = (ROOT / "project.yml").read_text()
        self.assertNotIn("hyperframes", project.lower())
        self.assertNotIn("install_motion_skills", project)


if __name__ == "__main__":
    unittest.main()