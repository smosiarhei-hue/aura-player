# Path: .github/scripts/patch_project_signing.py
"""Patch project.yml with developer signing credentials."""

import re
import sys
from pathlib import Path


def patch_project(project_path: Path, bundle_id: str, team_id: str, identity: str, profile_uuid: str = "") -> str:
    content = project_path.read_text(encoding="utf-8")

    # Keep each nested bundle distinct. A widget must never share the app's ID.
    def identifier(match):
        old = match.group(1)
        suffix = next(("." + part for part in ("LiveActivity", "UnitTests", "UITests") if old.endswith("." + part)), "")
        return "PRODUCT_BUNDLE_IDENTIFIER: " + bundle_id + suffix
    content = re.sub(r"PRODUCT_BUNDLE_IDENTIFIER:\s*([A-Za-z0-9_.-]+)", identifier, content)
    content = re.sub(r"CFBundleURLName:\s*[A-Za-z0-9_.-]+", f"CFBundleURLName: {bundle_id}", content)
    if profile_uuid:
        # Per-target profile: command-line profile settings would incorrectly override the widget.
        start = content.index("  Sonivo:\n")
        end = re.search(r"^  [A-Za-z][A-Za-z0-9_]*:\n", content[start + 1:], re.MULTILINE)
        stop = start + 1 + end.start() if end else len(content)
        app = content[start:stop]
        app = app.replace(f"PRODUCT_BUNDLE_IDENTIFIER: {bundle_id}\n",
            f'PRODUCT_BUNDLE_IDENTIFIER: {bundle_id}\n        PROVISIONING_PROFILE_SPECIFIER: "{profile_uuid}"\n', 1)
        content = content[:start] + app + content[stop:]

    # Enable signing in both root and target settings
    content = re.sub(
        r"DEVELOPMENT_TEAM:\s*\"?[^\n\"]*\"?",
        f'DEVELOPMENT_TEAM: "{team_id}"',
        content,
    )
    content = re.sub(r"CODE_SIGNING_ALLOWED:\s*NO", "CODE_SIGNING_ALLOWED: YES", content)
    content = re.sub(r"CODE_SIGNING_REQUIRED:\s*NO", "CODE_SIGNING_REQUIRED: YES", content)
    content = re.sub(
        r"CODE_SIGN_IDENTITY:\s*\"?[^\n\"]*\"?",
        f'CODE_SIGN_IDENTITY: "{identity}"',
        content,
    )

    project_path.write_text(content, encoding="utf-8")
    return content


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: patch_project_signing.py <bundle_id> <team_id> <identity> [profile_uuid] [project_path]")
        sys.exit(1)

    bundle_id_arg = sys.argv[1]
    team_id_arg = sys.argv[2]
    identity_arg = sys.argv[3]
    profile_uuid_arg = sys.argv[4] if len(sys.argv) > 4 else ""
    project_path_arg = Path(sys.argv[5]) if len(sys.argv) > 5 else Path("project.yml")

    patch_project(project_path_arg, bundle_id_arg, team_id_arg, identity_arg, profile_uuid_arg)
    print(f"Successfully patched {project_path_arg} for bundle {bundle_id_arg}, team {team_id_arg}")
