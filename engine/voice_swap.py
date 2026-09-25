#!/usr/bin/env python3
"""Re-sing a song's vocal in another person's voice, keeping melody, timing and words (Separator venv).

    python voice_swap.py VOCALS.wav VOICE_SAMPLE.wav --out SWAPPED.wav [--shift 0|12|-12] [--steps 50]

VOCALS.wav is the song's split vocal (stems.py --vocals-only); VOICE_SAMPLE.wav is 10–30 s of the
target voice singing, dry and alone. Runs Seed-VC's singing model (scripts/setup_seedvc.sh), then
resamples its 44.1 kHz output to the vocal's rate, re-aligns it to the sample (envelope
cross-correlation) and restores the original vocal level, so it drops straight back onto the band
(vocal_mix.py). --shift moves the melody by whole octaves only, so it stays in the song's key; use
it when the song's singer sits far from the target voice's range. Summary: `[result] {json}`.
Only use voices you have the right to use.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import correlate, resample_poly


def seedvc_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/YuE2Mac/SeedVC"
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "YuE2Mac/SeedVC"


def envelope(x: np.ndarray, hop: int) -> np.ndarray:
    return np.sqrt(np.convolve(x.mean(axis=1) ** 2, np.ones(hop) / hop, "same")[::hop])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vocals", type=Path)
    ap.add_argument("voice_sample", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--shift", type=int, default=0, choices=(-12, 0, 12))
    ap.add_argument("--steps", type=int, default=50, help="diffusion steps (Seed-VC: 30–50 for singing)")
    a = ap.parse_args()

    base = seedvc_dir()
    if not (base / "venv/bin/python").exists():
        raise SystemExit("Seed-VC isn't installed. Run scripts/setup_seedvc.sh.")
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, HF_HOME=str(base / "hf"))
        subprocess.run([str(base / "venv/bin/python"), "inference.py", "--source", str(a.vocals.resolve()),
                        "--target", str(a.voice_sample.resolve()), "--output", tmp,
                        "--diffusion-steps", str(a.steps), "--f0-condition", "True",
                        "--semi-tone-shift", str(a.shift), "--fp16", "False"],
                       cwd=base / "src", env=env, check=True, stdout=sys.stderr)
        vc, vc_sr = sf.read(next(Path(tmp).glob("*.wav")), always_2d=True)

    orig, sr = sf.read(a.vocals, always_2d=True)
    g = np.gcd(sr, vc_sr)
    vc = resample_poly(vc, sr // g, vc_sr // g, axis=0)
    hop = sr // 100
    e1, e2 = envelope(orig, hop), envelope(vc, hop)
    n = min(len(e1), len(e2))
    c = correlate(e2[:n] - e2[:n].mean(), e1[:n] - e1[:n].mean(), "full")
    lag = int((np.argmax(c) - (n - 1)) * hop)
    vc = vc[lag:] if lag > 0 else np.vstack([np.zeros((-lag, vc.shape[1])), vc])
    vc = np.vstack([vc[: len(orig)], np.zeros((max(0, len(orig) - len(vc)), vc.shape[1]))])
    if vc.shape[1] == 1 and orig.shape[1] == 2:
        vc = np.repeat(vc, 2, axis=1)
    vc *= np.sqrt((orig ** 2).mean() / ((vc ** 2).mean() + 1e-12))
    a.out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(a.out, vc.astype(np.float32), sr, subtype="FLOAT")
    print("[result] " + json.dumps({"out": str(a.out), "shift": a.shift, "offset_ms": round(lag / sr * 1000, 1)}),
          flush=True)


if __name__ == "__main__":
    main()
