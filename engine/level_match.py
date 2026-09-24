#!/usr/bin/env python3
"""Loudness-match audio files for A/B listening WITHOUT changing the sound.

    python level_match.py OUT_DIR IN.wav[=Name] …  [--target -16] [--peak -1]

Pure gain only: each file is scaled by one constant so its integrated loudness (ITU-R BS.1770,
EBU R128 gating) hits the target, lowered further if that would push the true-ish peak above
--peak dBFS. No compression, limiting or dynamic processing — the copy is bit-for-bit the
original times a gain. (ffmpeg's one-pass `loudnorm` runs in dynamic mode and audibly squashed
our earlier listening copies: 14–16 dB residual, dynamic range cut by up to 5 dB.)
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf


def k_weighted_loudness(x: np.ndarray, sr: int) -> float:
    """Integrated loudness in LUFS (BS.1770-4: K-weighting, 400 ms blocks, absolute + relative gates)."""
    from scipy.signal import bilinear, lfilter
    # Stage 1: high-shelf (+4 dB above ~1.5 kHz); stage 2: RLB high-pass. Coefficients for any rate.
    import math
    f0, G, Q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    K = math.tan(math.pi * f0 / sr)
    Vh, Vb = 10 ** (G / 20), 10 ** (G / 20) ** 0.4996667741545416
    a0 = 1 + K / Q + K * K
    b1 = [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0]
    a1 = [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
    f0, Q = 38.13547087602444, 0.5003270373238773
    K = math.tan(math.pi * f0 / sr)
    b2 = [1, -2, 1]
    a2 = [1, 2 * (K * K - 1) / (1 + K / Q + K * K), (1 - K / Q + K * K) / (1 + K / Q + K * K)]
    y = lfilter(b2, a2, lfilter(b1, a1, x, axis=0), axis=0)
    block, hop = int(0.4 * sr), int(0.1 * sr)
    ms = np.array([np.mean(y[i:i + block] ** 2, axis=0).sum() for i in range(0, len(y) - block, hop)])
    lk = -0.691 + 10 * np.log10(ms + 1e-12)
    ms = ms[lk > -70]
    rel = -0.691 + 10 * np.log10(ms.mean() + 1e-12) - 10
    ms = ms[(-0.691 + 10 * np.log10(ms + 1e-12)) > rel]
    return float(-0.691 + 10 * np.log10(ms.mean() + 1e-12))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out_dir", type=Path)
    ap.add_argument("items", nargs="+", help="IN.wav or IN.wav=Output name")
    ap.add_argument("--target", type=float, default=-16.0, help="LUFS (default -16)")
    ap.add_argument("--peak", type=float, default=-1.0, help="max sample peak, dBFS")
    a = ap.parse_args()
    a.out_dir.mkdir(parents=True, exist_ok=True)
    for item in a.items:
        src, _, name = item.partition("=")
        x, sr = sf.read(src, always_2d=True, dtype="float64")
        lufs = k_weighted_loudness(x, sr)
        gain_db = a.target - lufs
        peak_db = 20 * np.log10(np.abs(x).max() + 1e-12)
        if peak_db + gain_db > a.peak:
            gain_db = a.peak - peak_db
        y = x * 10 ** (gain_db / 20)
        dst = a.out_dir / f"{name or Path(src).stem}.wav"
        sf.write(str(dst), y, sr, subtype="PCM_24")
        print(f"{dst.name:70s} {lufs:6.1f} LUFS → {lufs + gain_db:6.1f} (gain {gain_db:+.1f} dB)", flush=True)


if __name__ == "__main__":
    main()
