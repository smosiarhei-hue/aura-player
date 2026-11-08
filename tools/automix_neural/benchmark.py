#!/usr/bin/env python3
"""Offline Beat This! small0 experiment. Not an iOS/runtime dependency."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import time

import numpy as np
import onnxruntime as ort

RATE = 22050
FPS = 50
MAX_SECONDS = 25
FILES = {
    'mel_spectrogram.onnx': 'fdd59e65c515331308e4c8841edf99972deca646bdf6197744c2a5b7755e3de9',
    'beat_this_small.onnx': 'a5f8d39d989f31859454ba27afe61c5317ca95e4d9373e6853e5361b8937172f',
}


def load_models(directory):
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 2
    opts.inter_op_num_threads = 1
    models = []
    for name, expected in FILES.items():
        path = pathlib.Path(directory) / name
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected:
            raise ValueError(f'Wrong model checksum: {name}')
        models.append(ort.InferenceSession(str(path), sess_options=opts,
                                           providers=['CPUExecutionProvider']))
    return models


def peaks(logits):
    # Local max within +/-3 frames; one event per plateau. Threshold 0 = sigmoid 0.5.
    found = []
    for i, value in enumerate(logits):
        if value > 0 and value >= np.max(logits[max(0, i - 3):i + 4]):
            if found and i - found[-1][-1] == 1:
                found[-1].append(i)
            else:
                found.append([i])
    return [float(np.mean(group)) / FPS for group in found]


def predict(samples, mel_model, beat_model):
    if samples.ndim != 1 or not 1 <= len(samples) <= RATE * MAX_SECONDS:
        raise ValueError('Expected mono audio, at most 25 seconds')
    if not np.isfinite(samples).all():
        raise ValueError('Audio contains non-finite samples')
    # Short experiment only: same six-frame border as upstream. Avoid long-audio
    # chunk stitching here; it must be implemented and validated before deployment.
    spect = mel_model.run(None, {'audio_pcm': samples.astype(np.float32)[None]})[0]
    chunk = np.pad(spect, ((0, 0), (6, 6), (0, 0)))
    beat, downbeat = beat_model.run(None, {'spectrogram': chunk})
    if beat.shape != downbeat.shape or beat.shape[1] != spect.shape[1] + 12:
        raise ValueError('Unexpected model output dimensions')
    if not (np.isfinite(beat).all() and np.isfinite(downbeat).all()):
        raise ValueError('Non-finite model output')
    return peaks(beat[0, 6:-6]), peaks(downbeat[0, 6:-6])


def click_track(drift=False):
    rng = np.random.default_rng(42)
    samples = np.zeros(RATE * 12, dtype=np.float32)
    t, index, truth = 0.25, 0, []
    while t < 11.8:
        truth.append(t)
        n = np.arange(4000, dtype=np.float64) / RATE
        wave = (0.75 if index % 4 == 0 else 0.4) * np.sin(2*np.pi*(95*n - 30*n*n))*np.exp(-n*20)
        wave += rng.normal(0, 0.15, len(n))*np.exp(-n*85)
        first = int(t * RATE)
        count = min(len(wave), len(samples) - first)
        samples[first:first + count] += wave[:count].astype(np.float32)
        t += 0.5 + (0.004 * index if drift else 0)
        index += 1
    return samples, truth, truth[::4]


def score(reference, predicted, tolerance=0.07):
    # One-to-one matching: count an event at most once.
    remaining = set(range(len(reference)))
    matches, errors = 0, []
    for event in predicted:
        if not remaining:
            break
        closest = min(remaining, key=lambda i: abs(reference[i] - event))
        delta = abs(reference[closest] - event)
        if delta <= tolerance:
            remaining.remove(closest)
            matches += 1
            errors.append(delta)
    return {'reference': len(reference), 'predicted': len(predicted), 'matched': matches,
            'false_positives': len(predicted) - matches,
            'misses': len(reference) - matches,
            'median_abs_error_ms': round(float(np.median(errors))*1000, 1) if errors else None}


def run_synthetic(models):
    report = {}
    for name, drift in [('steady_120_bpm', False), ('gradual_tempo_drift', True)]:
        samples, beats, downbeats = click_track(drift)
        t = time.perf_counter()
        predicted_beats, predicted_downbeats = predict(samples, *models)
        report[name] = {'beat': score(beats, predicted_beats),
                        'downbeat': score(downbeats, predicted_downbeats),
                        'elapsed_sec': round(time.perf_counter() - t, 3)}
    samples = np.zeros(RATE * 12, dtype=np.float32)
    t = time.perf_counter()
    beats, downbeats = predict(samples, *models)
    report['silence'] = {'beat_events': len(beats), 'downbeat_events': len(downbeats),
                         'elapsed_sec': round(time.perf_counter() - t, 3)}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', required=True, help='Directory with the two checksum-pinned ONNX files')
    parser.add_argument('--audio', help='Optional local audio; evaluates first 25 s without uploading it')
    args = parser.parse_args()
    models = load_models(args.model_dir)
    if args.audio:
        result = subprocess.run(['ffmpeg', '-v', 'error', '-i', args.audio, '-t', str(MAX_SECONDS),
                                 '-vn', '-ac', '1', '-ar', str(RATE), '-f', 'f32le', 'pipe:1'],
                                capture_output=True, check=True, timeout=60)
        samples = np.frombuffer(result.stdout, dtype='<f4')
        t = time.perf_counter()
        beats, downbeats = predict(samples, *models)
        report = {'duration_sec': len(samples)/RATE, 'beat_sec': beats, 'downbeat_sec': downbeats,
                  'elapsed_sec': round(time.perf_counter() - t, 3),
                  'note': 'Uncalibrated raw peak events, not a transition decision.'}
    else:
        report = run_synthetic(models)
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
