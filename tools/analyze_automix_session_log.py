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

    # Only consecutive heartbeat samples can indicate a freeze. ACTION-triggered
    # STATE snapshots can repeat within milliseconds and must not count as seconds.
    freeze_runs = 0
    run = 0
    last_pos = None
    last_track = None
    last_second = None
    for t in ticks:
        if t.get("_tag") != "TICK":
            continue
        try:
            hh, mm, ss = t["_ts"].split(":")
            second = int(hh) * 3600 + int(mm) * 60 + float(ss)
        except (KeyError, ValueError):
            second = None
        pos, track = t.get("pos"), t.get("A")
        gap = ((second - last_second) % 86400) if second is not None and last_second is not None else None
        eligible = t.get("play") == "1" and t.get("bufferA") != "1" and pos is not None
        if eligible and pos == last_pos and track == last_track and gap is not None and 0.5 <= gap <= 2.5:
            run += 1
            if run == 5:
                freeze_runs += 1
        else:
            run = 1 if eligible else 0
        last_pos = pos if eligible else None
        last_track = track if eligible else None
        last_second = second

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
    # Safe/ordinary crossfades finish without LAND. Old logs and partial pastes
    # cannot prove an absent LAND is a failure, so leave the outcome unconfirmed.
    outcome_names = ("transition.promoted", "transition.cancel", "transition.safe-abort",
                     "land.hardcut", "land.stream-fallback", "land.native-fallback")
    pending, unconfirmed = False, 0
    for event in events:
        if event.startswith("transition.schedule"):
            if pending:
                unconfirmed += 1
            pending = True
        elif pending and any(event.startswith(name) for name in outcome_names):
            pending = False
    unconfirmed += int(pending)
    transition_unconfirmed = unconfirmed > 0
    if any("land.recover" in f for f in faults + events):
        problems.append("land_recovery_fired")
        verdict = "broken"
    if any("playback.frozen" in f for f in faults) or freeze_runs:
        problems.append("playback_frozen")
        verdict = "broken"
    if mixing_pos_zero:
        problems.append("mixing_timeline_stuck_at_zero")
        verdict = "broken" if verdict != "ok" else "degraded"
    # Field: land.hardcut then ACTION next ~30ms later skipped landed B.
    land_then_next = False
    for i, line in enumerate(lines):
        if "[EVENT] land.hardcut" not in line:
            continue
        for follow in lines[i + 1 : i + 6]:
            if "[ACTION] next |" in follow:
                land_then_next = True
                break
            if "[EVENT] next.suppressed" in follow:
                break
        if land_then_next:
            break
    if land_then_next:
        # next() has both user and internal callers; this alone cannot prove a bug.
        problems.append("possible_skip_after_land")
        if verdict == "ok":
            verdict = "degraded"

    # Stem MIXING with dual-full volumes = pre-bed mud (field 1047).
    dual_full = 0
    for t in mixing:
        if t.get("bake") != "1":
            continue
        try:
            va = float(t.get("volA", "0"))
            vb = float(t.get("volB", "0"))
        except ValueError:
            continue
        if va >= 0.95 and vb >= 0.90:
            dual_full += 1
    if dual_full >= 3:
        problems.append("mixing_dual_full_volumes")
        if verdict == "ok":
            verdict = "degraded"

    bake_ready_meta: list[dict[str, str]] = []
    separation_backends: list[str] = []
    for e in events:
        if not e.startswith("bake.ready"):
            continue
        fields = parse_fields(e)
        bake_ready_meta.append(fields)
        if sep := fields.get("sep"):
            separation_backends.append(sep)
    fingerprints = sorted(
        {
            parse_fields(e).get("fp", "")
            for e in events
            if e.startswith("transition.schedule") and "fp=" in e
        }
        - {""}
    )

    decisions = [parse_fields(e) for e in events if e.startswith("transition.decision")]
    completions = [parse_fields(e) for e in events if e.startswith("transition.promoted")]
    if verdict == "ok" and (not has_event("transition.schedule") or transition_unconfirmed):
        verdict = "insufficient_data"
    elif verdict == "ok":
        verdict = "no_issue_detected"
    return {
        "verdict": verdict,
        "limitations": (["transition_outcome_unconfirmed"] if transition_unconfirmed else [])
                       + ["log_only_not_proof_of_audible_quality"],
        "unconfirmed_transitions": unconfirmed,
        "execution_decisions": decisions,
        "transition_completions": completions,
        "safe_fade_waits": sum(e.startswith("transition.safe-wait") for e in events),
        "safe_fade_aborts": sum(e.startswith("transition.safe-abort") for e in events),
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
        "mixing_dual_full_ticks": dual_full,
        "bake_ready_meta": bake_ready_meta,
        "separation_backends": separation_backends,
        "transition_fingerprints": fingerprints,
        "unique_transition_fingerprints": len(fingerprints),
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
