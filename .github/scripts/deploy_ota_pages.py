# Path: .github/scripts/deploy_ota_pages.py
"""Generate OTA manifest.plist and push to gh-pages branch."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


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


def _github_api(method: str, path: str, token: str, body: dict | None = None) -> tuple[int, object]:
    """Minimal GitHub REST helper (stdlib only — no PyGithub on the runner)."""
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        data=None if body is None else json.dumps(body).encode("utf-8"),
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "sonivo-ota-deploy",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            payload = json.loads(raw.decode("utf-8")) if raw else None
            return response.status, payload
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {"message": str(error)}
        except json.JSONDecodeError:
            payload = {"message": raw.decode("utf-8", errors="replace")}
        return error.code, payload
    except Exception as error:  # network / timeout — never fail the IPA job for this
        return 0, {"message": str(error)}


def cancel_in_progress_pages_deployments(token: str, repository: str) -> None:
    """Clear stuck GitHub Pages publish locks before pushing a new OTA IPA.

    Rapid Build IPA runs were stacking deploys: one ~57MB Sonivo.ipa hung in
    `syncing_files`, then every later `pages-build-deployment` failed with
    "cancel <sha> first". Cancel + mark GH Deployments inactive up front.
    """
    owner, repo = repository.split("/", 1)
    status_code, builds = _github_api("GET", f"/repos/{owner}/{repo}/pages/builds", token)
    if status_code != 200 or not isinstance(builds, list):
        print(f"Skip pages unlock (builds HTTP {status_code}): {builds}")
        return

    cancelled = 0
    for build in builds[:8]:
        if not isinstance(build, dict):
            continue
        if build.get("status") not in {"building", "queued"}:
            continue
        sha = (build.get("commit") or "").strip()
        if not sha:
            continue
        code, _ = _github_api(
            "POST",
            f"/repos/{owner}/{repo}/pages/deployments/{sha}/cancel",
            token,
        )
        print(f"Cancel pages deployment {sha[:7]} → HTTP {code}")
        cancelled += 1

    # Also retire GitHub Deployments still marked in_progress / queued for pages.
    status_code, deployments = _github_api(
        "GET",
        f"/repos/{owner}/{repo}/deployments?environment=github-pages&per_page=10",
        token,
    )
    if status_code == 200 and isinstance(deployments, list):
        for deployment in deployments:
            if not isinstance(deployment, dict):
                continue
            dep_id = deployment.get("id")
            if not dep_id:
                continue
            code, statuses = _github_api(
                "GET",
                f"/repos/{owner}/{repo}/deployments/{dep_id}/statuses",
                token,
            )
            latest = statuses[0]["state"] if code == 200 and isinstance(statuses, list) and statuses else ""
            if latest in {"in_progress", "queued", "pending"}:
                _github_api(
                    "POST",
                    f"/repos/{owner}/{repo}/deployments/{dep_id}/statuses",
                    token,
                    {"state": "inactive", "description": "Superseded by newer OTA Pages push"},
                )
                print(f"Mark deployment {dep_id} inactive (was {latest})")

    if cancelled == 0:
        print("No in-progress pages builds to cancel.")


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

    cancel_in_progress_pages_deployments(token, repository)

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
        print(f"Standard push to gh-pages rejected ({push_res.stderr.strip()}), retrying with rebase/force...")
        subprocess.run(["git", "-C", str(pages_dir), "pull", "--rebase", "-Xtheirs", "origin", "gh-pages"], capture_output=True)
        push_res = subprocess.run(["git", "-C", str(pages_dir), "push", "origin", "gh-pages"], capture_output=True, text=True)
        if push_res.returncode != 0:
            push_res = subprocess.run(["git", "-C", str(pages_dir), "push", "--force", "origin", "gh-pages"], capture_output=True, text=True)

    if push_res.returncode != 0:
        print(f"Failed to push to gh-pages: {push_res.stderr}")
        return 1

    print(f"Successfully deployed OTA build v{version} to GitHub Pages!")
    return 0


if __name__ == "__main__":
    sys.exit(deploy())
