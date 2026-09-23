# Path: .github/scripts/deploy_ota_pages.py
"""Generate OTA manifest.plist and push to gh-pages branch."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def generate_manifest(bundle_id: str, version: str, ipa_url: str, title: str = "Sonivo") -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key>
                    <string>software-package</string>
                    <key>url</key>
                    <string>{ipa_url}</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key>
                <string>{bundle_id}</string>
                <key>bundle-version</key>
                <string>{version}</string>
                <key>kind</key>
                <string>software</string>
                <key>title</key>
                <string>{title}</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
"""


def deploy(env=None):
    if env is None:
        env = os.environ

    token = env.get("GH_PAGES_TOKEN", "").strip()
    repository = env.get("GITHUB_REPOSITORY", "").strip()
    bundle_id = env.get("BUNDLE_ID", "app.hare5681.lyra4838").strip()
    version = env.get("MARKETING_VERSION", "1.1.0").strip()
    build_num = env.get("BUILD_NUMBER", "1").strip()
    temp_dir = Path(env.get("RUNNER_TEMP", tempfile.gettempdir()))

    if not token or not repository:
        print("Missing GH_PAGES_TOKEN or GITHUB_REPOSITORY, skipping OTA deploy.")
        return 0

    owner, repo_name = repository.split("/", 1)
    ipa_url = f"https://{owner}.github.io/{repo_name}/Sonivo.ipa"

    pages_dir = temp_dir / "gh_pages_deploy"
    if pages_dir.exists():
        shutil.rmtree(pages_dir)

    print(f"Cloning gh-pages branch from {repository}...")
    clone_url = f"https://x-access-token:{token}@github.com/{repository}.git"
    res = subprocess.run(
        ["git", "clone", "--depth", "1", "--branch", "gh-pages", clone_url, str(pages_dir)],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        print(f"Failed to clone gh-pages: {res.stderr}")
        return 1

    ipa_src = Path("Sonivo.ipa")
    if not ipa_src.exists():
        print("Sonivo.ipa not found for OTA deploy!")
        return 1

    shutil.copy2(ipa_src, pages_dir / "Sonivo.ipa")

    manifest_content = generate_manifest(bundle_id=bundle_id, version=version, ipa_url=ipa_url)
    (pages_dir / "manifest.plist").write_text(manifest_content, encoding="utf-8")

    subprocess.run(["git", "-C", str(pages_dir), "config", "user.name", "github-actions[bot]"], check=True)
    subprocess.run(
        ["git", "-C", str(pages_dir), "config", "user.email", "github-actions[bot]@users.noreply.github.com"],
        check=True,
    )
    subprocess.run(["git", "-C", str(pages_dir), "add", "Sonivo.ipa", "manifest.plist"], check=True)

    commit_res = subprocess.run(
        ["git", "-C", str(pages_dir), "commit", "-m", f"Deploy OTA Sonivo v{version} (#{build_num}) [skip ci]"],
        capture_output=True,
        text=True,
    )
    print(commit_res.stdout)

    push_res = subprocess.run(["git", "-C", str(pages_dir), "push", "origin", "gh-pages"], capture_output=True, text=True)
    if push_res.returncode != 0:
        print(f"Failed to push to gh-pages: {push_res.stderr}")
        return 1

    print(f"Successfully deployed OTA build v{version} to GitHub Pages!")
    return 0


if __name__ == "__main__":
    sys.exit(deploy())
