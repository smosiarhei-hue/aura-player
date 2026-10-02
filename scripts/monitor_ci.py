# Path: scripts/monitor_ci.py
"""Monitor GitHub Actions CI for the current commit until completion."""

import json
import os
import re
import subprocess
import sys
import time
import urllib.request

REPO = "smosiarhei-hue/aura-player"


def get_token():
    if "GITHUB_TOKEN" in os.environ:
        return os.environ["GITHUB_TOKEN"]
    # Extract from git remote origin url if available
    try:
        res = subprocess.run(["git", "config", "--get", "remote.origin.url"], capture_output=True, text=True, check=True)
        match = re.search(r"oauth2:([^@]+)@", res.stdout)
        if match:
            return match.group(1)
    except Exception:
        pass
    return None


def get_head_sha():
    result = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
    return result.stdout.strip()


def fetch_runs(token, head_sha):
    url = f"https://api.github.com/repos/{REPO}/actions/runs?head_sha={head_sha}"
    headers = {"User-Agent": "Sonivo-CI-Monitor", "Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode("utf-8")).get("workflow_runs", [])


def main():
    token = get_token()
    head_sha = get_head_sha()
    print(f"Monitoring GitHub Actions CI for commit {head_sha[:8]}...")

    runs = []
    for _ in range(6):
        runs = fetch_runs(token, head_sha)
        if runs:
            break
        print("Waiting for workflow run to register...")
        time.sleep(5)

    if not runs:
        print("No workflow runs found for commit.")
        sys.exit(1)

    run = [r for r in runs if r["name"] == "Build IPA"]
    run = run[0] if run else runs[0]
    run_id = run["id"]
    print(f"Tracking run {run_id} ({run['name']})...")

    start_time = time.time()
    while True:
        url = f"https://api.github.com/repos/{REPO}/actions/runs/{run_id}"
        headers = {"User-Agent": "Sonivo-CI-Monitor", "Accept": "application/vnd.github.v3+json"}
        if token:
            headers["Authorization"] = f"token {token}"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode("utf-8"))

        status = data.get("status")
        conclusion = data.get("conclusion")
        elapsed = int(time.time() - start_time)
        print(f"[{elapsed}s] Run {run_id}: status={status}, conclusion={conclusion}")

        if status == "completed":
            if conclusion == "success":
                print(f"CI Build IPA SUCCEEDED for commit {head_sha[:8]}!")
                sys.exit(0)
            else:
                print(f"CI Build IPA FAILED with conclusion: {conclusion}")
                sys.exit(1)

        time.sleep(15)


if __name__ == "__main__":
    main()
