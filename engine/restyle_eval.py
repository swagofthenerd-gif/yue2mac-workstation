#!/usr/bin/env python3
"""Score restyles against the original: does the timing still line up, and how different is it?

    python restyle_eval.py ORIGINAL.wav VERSION.wav [VERSION.wav …] --unrelated OTHER_SONG.wav

Run with a Python that has librosa (the Separator venv does). For each version:
  timing  — mean onset-envelope correlation over 20 s windows, best lag within ±250 ms
            (1.0 = identical rhythm; an unrelated song ≈ 0.07). ≥ 0.5 stayed in sync with the
            original vocals in our tests; below ≈ 0.35 it audibly drifts.
  change  — distance between 1-second timbre profiles (MFCC means), as a % of the distance to an
            unrelated song (100%).
  offsets — per-window best lag in ms; jumping offsets mean the groove was re-composed, not shifted.
Measured on "Awais-Lahasil demo 2" (2026-09-24), Stable Audio 3 Medium, MLX:
  strength 0.5 cfg1 → 0.79–0.82 / 29% · 0.5–0.55 cfg3–6 → 0.54–0.60 / 39–43% (ceiling while in sync)
  per-stem prompts at 0.55 cfg3 → 0.53–0.61 / 42–43% · ≥0.65 → 0.18–0.31 after shifting / 52–95%.
"""
import argparse
import os

import librosa
import numpy as np

SR, HOP = 22050, 256
FPS = SR / HOP
WIN = int(20 * FPS)


def feats(path, seconds=None):
    y, _ = librosa.load(path, sr=SR, mono=True, duration=seconds)
    env = librosa.onset.onset_strength(y=y, sr=SR, hop_length=HOP)
    mel = librosa.power_to_db(librosa.feature.melspectrogram(y=y, sr=SR, hop_length=HOP, n_mels=64))
    return env, librosa.feature.mfcc(S=mel, n_mfcc=20)


def timing(a, b, max_lag_s=0.25):
    lag_max = int(max_lag_s * FPS)
    corrs, offs = [], []
    for s in range(0, min(len(a), len(b)) - WIN, WIN):
        x = a[s:s + WIN] - a[s:s + WIN].mean()
        best = (-1.0, 0)
        for lag in range(-lag_max, lag_max + 1):
            if s + lag < 0 or s + lag + WIN > len(b):
                continue
            y = b[s + lag:s + lag + WIN] - b[s + lag:s + lag + WIN].mean()
            c = float(np.dot(x, y) / (np.linalg.norm(x) * np.linalg.norm(y) + 1e-9))
            if c > best[0]:
                best = (c, lag)
        corrs.append(best[0])
        offs.append(int(round(best[1] / FPS * 1000)))
    return float(np.mean(corrs)), offs


def timbre_distance(a, b):
    n, k = min(a.shape[1], b.shape[1]), int(FPS)
    A = np.stack([a[1:, i:i + k].mean(1) for i in range(0, n - k, k)])
    B = np.stack([b[1:, i:i + k].mean(1) for i in range(0, n - k, k)])
    return float(np.mean(np.linalg.norm(A - B, axis=1)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("original")
    ap.add_argument("versions", nargs="+")
    ap.add_argument("--unrelated", required=True, help="a different song, the 100% change reference")
    ap.add_argument("--max-lag", type=float, default=0.25)
    a = ap.parse_args()
    e0, m0 = feats(a.original)
    seconds = len(e0) / FPS
    _, mu = feats(a.unrelated, seconds)
    full = timbre_distance(m0, mu)
    print(f"{'version':40s} timing  change  offsets per 20 s (ms)")
    for v in a.versions:
        e, m = feats(v, seconds)
        t, offs = timing(e0, e, a.max_lag)
        print(f"{os.path.basename(v)[:40]:40s} {t:5.2f}  {timbre_distance(m0, m) / full * 100:5.0f}%  {offs}")


if __name__ == "__main__":
    main()
