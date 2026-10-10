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
        self.assertIn("SonivoLaunchDisplay".encode("utf-16-be"), tables[b"name"])
        self.assertIn("SIL OPEN FONT LICENSE", (ROOT / "ThirdPartyNotices/Unbounded-OFL.txt").read_text())
        self.assertIn("guard !didPrepare", source)
        self.assertIn("CTFontManagerRegisterGraphicsFont(font, nil)", source)
        self.assertNotIn("URLSession", source)

    def test_font_registration_happens_before_the_shared_animation_clock(self):
        source = (ROOT / "Sonivo/SonivoLaunchIntro.swift").read_text()
        register = source.index("brandFontName = SonivoLaunchTypography.prepare()")
        self.assertLess(source.index("RootView(onExternalPlaybackOpen: finish)"), register)
        self.assertLess(source.index("guard session.begin("), register)
        self.assertLess(register, source.index("epoch = haptics.start"))
        word = source[source.index("private func focusedWord"):source.index("private func blend")]
        self.assertNotIn("prepare()", word)
        self.assertIn("Font.custom($0, fixedSize: fontSize)", word)
        self.assertIn("?? .system(size: fontSize, weight: .bold)", word)

    def test_chrome_is_word_only_premultiplied_sdr_and_respects_accessibility(self):
        source = (ROOT / "Sonivo/SonivoLaunchIntro.swift").read_text()
        metal = (ROOT / "Sonivo/SonivoLaunchSurface.metal").read_text()
        self.assertIn("ShaderLibrary.sonivoLaunchChrome", source)
        self.assertIn("let materialEnabled = index == 0 && !reduceMotion && contrast != .increased", source)
        self.assertIn("isEnabled: materialEnabled", source)
        callback = source[source.index(".visualEffect {"):source.index(".blur(radius: blur)")]
        for actor_read in ["colorScheme ==", "contrast !=", "reduceMotion", "surfaceTime(at: time)"]:
            self.assertNotIn(actor_read, callback)
        self.assertIn("source.a <= half(0.0)", metal)
        self.assertIn("* source.a, source.a", metal)
        self.assertIn("clamp(rgb, float3(0.0), float3(1.0))", metal)
        self.assertIn("clamp(time, 0.0f, 4.2f)", metal)
        self.assertNotIn("texture2d", metal)
        self.assertNotIn("for (", metal)
        self.assertNotIn("while (", metal)
        self.assertIn(".blur(radius: blur)", source)  # True Focus, not slow-motion smear

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