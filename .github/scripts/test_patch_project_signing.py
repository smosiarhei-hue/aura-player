# Path: .github/scripts/test_patch_project_signing.py
"""Unit tests for project.yml signing patch script."""

import tempfile
import unittest
from pathlib import Path

from patch_project_signing import patch_project


SAMPLE_PROJECT_YML = """name: Sonivo
options:
  bundleIdPrefix: com.smoze
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
packages:
  AutoMixV2:
    path: Packages/AutoMixV2
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    DEVELOPMENT_TEAM: ""
    CODE_SIGN_STYLE: Manual
    CODE_SIGNING_ALLOWED: NO
    CODE_SIGNING_REQUIRED: NO
    CODE_SIGN_IDENTITY: ""
targets:
  Sonivo:
    type: application
    platform: iOS
    sources:
      - Aurora
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.smoze.sonivo
        TARGETED_DEVICE_FAMILY: "1"
        MARKETING_VERSION: "1.1.0"
        CURRENT_PROJECT_VERSION: "2"
        CODE_SIGNING_ALLOWED: NO
        CODE_SIGNING_REQUIRED: NO
        CODE_SIGN_IDENTITY: ""
    info:
      path: Aurora/Info.plist
      properties:
        CFBundleDisplayName: Sonivo
        CFBundleURLTypes:
          - CFBundleURLName: com.smoze.sonivo
            CFBundleURLSchemes:
              - sonivo
"""


class TestPatchProjectSigning(unittest.TestCase):
    def test_patch_project(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = Path(tmpdir) / "project.yml"
            file_path.write_text(SAMPLE_PROJECT_YML, encoding="utf-8")

            patch_project(
                project_path=file_path,
                bundle_id="app.hare5681.lyra4838",
                team_id="4RVYU38Y85",
                identity="iPhone Distribution: Yi Guo (4RVYU38Y85)",
                profile_uuid="test-uuid",
            )

            result = file_path.read_text(encoding="utf-8")

            # Verify bundle ID replaced
            self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: app.hare5681.lyra4838", result)
            self.assertIn("CFBundleURLName: app.hare5681.lyra4838", result)
            self.assertNotIn("com.smoze.sonivo", result)

            # Verify team ID
            self.assertIn('DEVELOPMENT_TEAM: "4RVYU38Y85"', result)

            # Verify code signing enabled
            self.assertNotIn("CODE_SIGNING_ALLOWED: NO", result)
            self.assertNotIn("CODE_SIGNING_REQUIRED: NO", result)
            self.assertIn("CODE_SIGNING_ALLOWED: YES", result)
            self.assertIn("CODE_SIGNING_REQUIRED: YES", result)
            self.assertIn('CODE_SIGN_IDENTITY: "iPhone Distribution: Yi Guo (4RVYU38Y85)"', result)


if __name__ == "__main__":
    unittest.main()
