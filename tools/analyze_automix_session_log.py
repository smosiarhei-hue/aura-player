#!/usr/bin/env python3
"""Offline AutoMix session-log triage for agents.

Reads a pasted Sonivo AutoMix Session Log (file path or stdin) and prints a
short JSON verdict: which transition path ran, bake/LAND outcomes, and whether
playback froze. Used when a user pastes a field log into chat.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

TICK_RE = re.compile(
    r"\[(?P<ts>[^\]]+)\]\[(?P<tag>TICK|STATE|EVENT|FAULT|ACTION)\]\s+(?P<body>.+)$"
)
FIELD_RE = re.compile(r"(\w+)=([^\s]+)")


def parse_fields(body: str) -> dict[str, str]:
    return {m.group(1): m.group(2) for m in FIELD_RE.finditer(body)}


def analyze(text: str) -> dict:
    lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
    events: list[str] = []
    faults: list[str] = []
    ticks: list[dict] = []
    actions: list[str] = []

    for ln in lines:
        m = TICK_RE.search(ln)
        if not m:
            continue
        tag = m.group("tag")
        body = m.group("body")
        if tag in ("EVENT",):
            events.append(body)
        elif tag == "FAULT":
            faults.append(body)
        elif tag == "ACTION":
            actions.append(body)
        elif tag in ("TICK", "STATE"):
            fields = parse_fields(body)
            fields["_tag"] = tag
            fields["_ts"] = m.group("ts")
            ticks.append(fields)

    def has_event(prefix: str) -> bool:
        return any(e.startswith(prefix) or prefix in e for e in events)

    freeze_runs = 0
    run = 0
    last_pos = None
    for t in ticks:
        if t.get("play") != "1":
            run = 0
            last_pos = None
            continue
        pos = t.get("pos")
        if pos is not None and pos == last_pos:
            run += 1
            if run == 5:
                freeze_runs += 1
        else:
            run = 1
            last_pos = pos

    mixing = [t for t in ticks if t.get("badge") == "MIXING" or t.get("tx") == "1"]
    mixing_pos_zero = bool(mixing) and all(t.get("pos") in ("0.0", "0") for t in mixing)

    verdict = "ok"
    problems: list[str] = []
    if any(f.startswith("bake.fail") or "bake.fail" in f for f in faults + events):
        problems.append("stem_bake_failed")
        verdict = "degraded"
    if not has_event("bake.ready") and has_event("bake.start"):
        problems.append("bake_started_without_ready")
        verdict = "degraded"
    if has_event("transition.schedule") and not (
        has_event("land.hardcut") or has_event("land.stream-fallback") or has_event("land.native-fallback")
    ):
        # Transition may still be in progress in a partial paste.
        if any(t.get("tx") == "0" for t in ticks[len(ticks) // 2 :]):
            problems.append("missing_land_event")
            verdict = "broken"
    if any("land.recover" in f for f in faults + events):
        problems.append("land_recovery_fired")
        verdict = "broken"
    if any("playback.frozen" in f for f in faults) or freeze_runs:
        problems.append("playback_frozen")
        verdict = "broken"
    if mixing_pos_zero:
        problems.append("mixing_timeline_stuck_at_zero")
        verdict = "broken" if verdict != "ok" else "degraded"

    return {
        "verdict": verdict,
        "problems": problems,
        "events": events,
        "faults": faults,
        "actions": actions[-12:],
        "tick_count": len(ticks),
        "freeze_runs_ge_5s": freeze_runs,
        "had_transition_schedule": has_event("transition.schedule"),
        "had_bake_start": has_event("bake.start"),
        "had_bake_ready": has_event("bake.ready"),
        "had_land_hardcut": has_event("land.hardcut"),
        "mixing_ticks": len(mixing),
        "mixing_timeline_stuck_at_zero": mixing_pos_zero,
    }


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] not in ("-", "--stdin"):
        text = Path(argv[1]).read_text(encoding="utf-8")
    else:
        text = sys.stdin.read()
    if not text.strip():
        print(json.dumps({"verdict": "empty", "problems": ["no_input"]}, ensure_ascii=False, indent=2))
        return 2
    print(json.dumps(analyze(text), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
