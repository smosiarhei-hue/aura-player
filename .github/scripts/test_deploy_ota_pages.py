# Path: .github/scripts/test_deploy_ota_pages.py
"""Unit tests for deploy_ota_pages.py."""

import unittest
from deploy_ota_pages import generate_manifest


class TestDeployOTAPages(unittest.TestCase):
    def test_generate_manifest(self):
        manifest = generate_manifest(
            bundle_id="app.hare5681.lyra4838",
            version="1.0.605",
            ipa_url="https://smosiarhei-hue.github.io/aura-player/Sonivo.ipa",
            title="Sonivo",
        )
        self.assertIn("app.hare5681.lyra4838", manifest)
        self.assertIn("1.0.605", manifest)
        self.assertIn("https://smosiarhei-hue.github.io/aura-player/Sonivo.ipa", manifest)
        self.assertIn("<string>software-package</string>", manifest)
        self.assertIn("<string>Sonivo</string>", manifest)


if __name__ == "__main__":
    unittest.main()
