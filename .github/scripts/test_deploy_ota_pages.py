# Path: .github/scripts/test_deploy_ota_pages.py
"""Unit tests for deploy_ota_pages.py."""

import unittest
from pathlib import Path
from unittest import mock

from deploy_ota_pages import cancel_in_progress_pages_deployments, deploy, generate_manifest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / ".github/scripts/deploy_ota_pages.py").read_text(encoding="utf-8")


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

    def test_deploy_cancels_stuck_pages_before_push(self):
        self.assertIn("cancel_in_progress_pages_deployments", SOURCE)
        self.assertIn("/pages/deployments/", SOURCE)
        self.assertIn("Superseded by newer OTA Pages push", SOURCE)
        # Wire-up: unlock runs before cloning gh-pages.
        self.assertLess(
            SOURCE.index("cancel_in_progress_pages_deployments(token, repository)"),
            SOURCE.index('clone", "--depth", "1", "--branch", "gh-pages"'),
        )

    def test_cancel_helper_posts_cancel_for_building_commits(self):
        calls: list[tuple[str, str]] = []

        def fake_api(method, path, token, body=None):
            calls.append((method, path))
            if path.endswith("/pages/builds"):
                return 200, [
                    {"status": "building", "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
                    {"status": "built", "commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
                ]
            if "/deployments?" in path:
                return 200, [{"id": 42}]
            if path.endswith("/statuses") and method == "GET":
                return 200, [{"state": "in_progress"}]
            return 204, None

        with mock.patch("deploy_ota_pages._github_api", side_effect=fake_api):
            cancel_in_progress_pages_deployments("token", "smosiarhei-hue/aura-player")

        self.assertIn(
            ("POST", "/repos/smosiarhei-hue/aura-player/pages/deployments/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/cancel"),
            calls,
        )
        self.assertIn(
            ("POST", "/repos/smosiarhei-hue/aura-player/deployments/42/statuses"),
            calls,
        )


if __name__ == "__main__":
    unittest.main()
