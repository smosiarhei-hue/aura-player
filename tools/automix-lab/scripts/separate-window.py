#!/usr/bin/env python3
"""Separate one Yandex transition window into vocals + instrumental.

Uses HTDemucs via demucs-onnx (https://github.com/StemSplit/demucs-onnx).
The model eats fixed 7.8 s chunks and runs faster than realtime on CPU,
so AutoMix can finish the mix window while the song is still playing.
Yandex Music does not return stems; this splits the downloaded mix.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf


def slice_wav(src: Path, start: float, duration: float, dest: Path) -> None:
    cmd = [
        "ffmpeg",
        "-y",
        "-ss",
        f"{max(0.0, start):.3f}",
        "-t",
        f"{max(1.0, duration):.3f}",
        "-i",
        str(src),
        "-ac",
        "2",
        "-ar",
        "44100",
        str(dest),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not dest.exists():
        tail = (proc.stderr or "")[-400:]
        raise RuntimeError(f"ffmpeg failed: {tail}")


def as_time_major(stem: np.ndarray, frames: int) -> np.ndarray:
    arr = np.asarray(stem, dtype=np.float32)
    if arr.ndim == 1:
        arr = arr[:, None]
    if arr.shape[0] <= 8 and arr.shape[-1] != frames and arr.shape[0] != frames:
        arr = arr.T
    if arr.shape[0] == frames:
        return arr
    if arr.shape[-1] == frames:
        return arr.T
    n = min(frames, arr.shape[0] if arr.shape[0] > arr.shape[-1] else arr.shape[-1])
    if arr.shape[0] >= arr.shape[-1]:
        return arr[:n]
    return arr.T[:n]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--start", type=float, required=True)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--track-id", required=True)
    args = parser.parse_args()

    src = Path(args.input)
    if not src.is_file():
        print(json.dumps({"ok": False, "error": "input missing"}))
        return 2

    try:
        from demucs_onnx import separate_stem
    except ImportError:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "demucs-onnx is not installed (pip install demucs-onnx)",
                    "repo": "https://github.com/StemSplit/demucs-onnx",
                }
            )
        )
        return 2

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sonivo-stem-") as tmp:
        window = Path(tmp) / "window.wav"
        slice_wav(src, args.start, args.duration, window)
        mix, sr = sf.read(window, always_2d=True, dtype="float32")
        vocals = separate_stem(
            window,
            "vocals",
            precision="fp16weights",
            providers="cpu",
        )
        vocal_tm = as_time_major(vocals, mix.shape[0])
        n = min(mix.shape[0], vocal_tm.shape[0])
        ch = min(mix.shape[1], vocal_tm.shape[1] if vocal_tm.ndim > 1 else 1)
        vocal_use = vocal_tm[:n, :ch]
        if vocal_use.ndim == 1:
            vocal_use = vocal_use[:, None]
        if vocal_use.shape[1] == 1 and mix.shape[1] == 2:
            vocal_use = np.repeat(vocal_use, 2, axis=1)
        dry = mix[:n, : vocal_use.shape[1]]
        instrumental = dry - vocal_use
        peak = float(np.max(np.abs(instrumental))) if instrumental.size else 1.0
        if peak > 0.98:
            instrumental *= 0.98 / peak
        sf.write(out / "vocals.wav", vocal_use, sr)
        sf.write(out / "instrumental.wav", instrumental, sr)
        beat_name = None
        try:
            drums = separate_stem(
                window,
                "drums",
                precision="fp16weights",
                providers="cpu",
            )
            beat = as_time_major(drums, n)
            beat = beat[:n]
            if beat.ndim == 1:
                beat = beat[:, None]
            if beat.shape[1] == 1 and dry.shape[1] == 2:
                beat = np.repeat(beat, 2, axis=1)
            beat = beat[:, : dry.shape[1]]
            peak_b = float(np.max(np.abs(beat))) if beat.size else 1.0
            if peak_b > 0.98:
                beat *= 0.98 / peak_b
            sf.write(out / "beat.wav", beat, sr)
            beat_name = "beat.wav"
        except Exception as exc:  # noqa: BLE001 — vocals job must still succeed
            print(json.dumps({"ok": False, "beat": str(exc)}), file=sys.stderr)

    meta = {
        "ok": True,
        "trackId": args.track_id,
        "startSec": args.start,
        "durationSec": args.duration,
        "engine": "htdemucs-vocals",
        "repo": "https://github.com/StemSplit/demucs-onnx",
        "vocals": "vocals.wav",
        "instrumental": "instrumental.wav",
        "beat": beat_name,
    }
    (out / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 — surface to the lab status line
        print(json.dumps({"ok": False, "error": str(exc)}))
        raise SystemExit(1)
