#!/usr/bin/env python3
"""Install pinned, project-local instruction files; never execute downloaded code.

Python standard library only. Run from any directory:
    python3 scripts/install_motion_skills.py
App builds do not invoke this script or require a network connection.
"""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def install():
    lock = json.loads((ROOT / "agent_skills/motion-skills.lock.json").read_text())
    destination = ROOT / ".agents/skills"
    destination.mkdir(parents=True, exist_ok=True)
    for package in lock["packages"]:
        repo, commit = package["repository"], package["commit"]
        url = f"https://codeload.github.com/{repo}/tar.gz/{commit}"
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read(512 * 1024 * 1024 + 1)
        if len(data) > 512 * 1024 * 1024:
            raise ValueError(f"Archive exceeds installation limit: {repo}")
        if hashlib.sha256(data).hexdigest() != package["archive_sha256"]:
            raise ValueError(f"Archive hash mismatch: {repo}")
        expected = {item["path"]: item["sha256"] for item in package["files"]}
        seen = set()
        pending = {}
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            for member in archive.getmembers():
                if not member.isfile():
                    continue
                parts = Path(member.name).parts[1:]
                if repo.startswith("twostraws/"):
                    relative = Path(*parts) if parts else Path(".")
                else:
                    if not parts or parts[0] != "skills":
                        continue
                    relative = Path(*parts[1:])
                key = str(relative)
                if key not in expected:
                    continue
                if relative.is_absolute() or ".." in relative.parts or member.size > 10 * 1024 * 1024:
                    raise ValueError(f"Unsafe skill path: {key}")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError(f"Unreadable skill file: {key}")
                content = stream.read()
                if hashlib.sha256(content).hexdigest() != expected[key]:
                    raise ValueError(f"File hash mismatch: {key}")
                pending[relative] = content
                seen.add(key)
        if seen != set(expected):
            raise ValueError(f"Missing pinned skill files: {repo}")
        # Validate the entire package before writing it. No shell hooks or executable installers.
        for relative, content in pending.items():
            target = destination / relative
            if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
                raise ValueError(f"Refusing symlink destination: {relative}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        print(f"Installed {repo}@{commit[:12]}: {len(pending)} verified files")
    print("Project-local skills installed. Native app runtime and dependencies unchanged.")


if __name__ == "__main__":
    install()
