#!/usr/bin/env python3
"""Restore the pinned UI UX Pro Max instruction snapshot; execute no downloaded code."""
import hashlib, io, json, tarfile, urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def install():
    lock=json.loads((ROOT/'agent_skills/ui-ux-pro-max.lock.json').read_text())
    url=f"https://codeload.github.com/{lock['repository']}/tar.gz/{lock['commit']}"
    data=urllib.request.urlopen(url,timeout=120).read(128*1024*1024+1)
    if len(data)>128*1024*1024 or hashlib.sha256(data).hexdigest()!=lock['archive_sha256']:raise ValueError('Archive mismatch')
    expected={f['path']:f['sha256'] for f in lock['files']};pending={}
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive.getmembers():
            if not member.isfile():continue
            rel=member.name.split('/',1)[-1];prefix='.claude/skills/ui-ux-pro-max/'
            key=rel[len(prefix):] if rel.startswith(prefix) else ('LICENSE' if rel=='LICENSE' else None)
            if key not in expected:continue
            path=Path(key)
            if path.is_absolute() or '..' in path.parts or member.size>10*1024*1024:raise ValueError('Unsafe path')
            content=archive.extractfile(member).read()
            if hashlib.sha256(content).hexdigest()!=expected[key]:raise ValueError('File mismatch')
            pending[path]=content
    if set(map(str,pending))!=set(expected):raise ValueError('Missing files')
    for rel,content in pending.items():
        target=ROOT/'.agents/skills/ui-ux-pro-max'/rel
        if target.is_symlink() or any(p.is_symlink() for p in target.parents):raise ValueError('Symlink target')
        target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(content)
    print(f'Restored {len(pending)} verified instruction files; native runtime unchanged.')
if __name__=='__main__':install()
