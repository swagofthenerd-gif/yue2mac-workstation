#!/usr/bin/env python3
"""Two-pass stem split with UVR models, levels kept true to the mix (Separator venv).

    python stems.py SONG --out DIR [--vocal-model M] [--band-model htdemucs_ft|htdemucs_6s]

Pass 1 (vocal eviction): a BS-RoFormer (default: BS-Roformer-Viperx-1297, the cleanest
instrumental in the UVR catalogue) splits vocals from the instrumental.
Pass 2 (instrument split): Demucs v4 fine-tuned splits the *instrumental* into drums, bass
and other (or drums, bass, guitar, piano, other with htdemucs_6s), so no vocal bleeds in.

audio-separator peak-normalises each file by default, which breaks relative levels; this
runs with normalisation off and then least-squares re-fits each pass's stem gains to its
input, so vocals + instrumental ≈ song and the band stems ≈ instrumental. Everything is
48 kHz, stereo, exactly the input's length, and written as vocals.wav, instrumental.wav,
drums.wav, bass.wav, other.wav (+ guitar.wav, piano.wav). Progress: `[stems] …`; summary:
`[result] {json}`.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf

RATE = 48000
VOCAL_MODEL = "model_bs_roformer_ep_317_sdr_12.9755.ckpt"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def decode(path: Path, ffmpeg: str) -> np.ndarray:
    raw = subprocess.run([ffmpeg, "-v", "error", "-nostdin", "-i", str(path), "-ac", "2", "-ar", str(RATE),
                          "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)


def fit_length(x: np.ndarray, n: int) -> np.ndarray:
    x = x[:n]
    return np.pad(x, ((0, n - len(x)), (0, 0))) if len(x) < n else x


def refit(target: np.ndarray, parts: dict) -> dict:
    """Scale each part so their sum best matches `target` (least squares, one gain per part)."""
    names = list(parts)
    A = np.stack([parts[n].reshape(-1) for n in names], axis=1)
    gains, *_ = np.linalg.lstsq(A, target.reshape(-1), rcond=None)
    gains = np.clip(gains, 0.25, 4.0)  # a sane range; separation outputs are near unity already
    return {n: parts[n] * g for n, g in zip(names, gains)}, dict(zip(names, map(float, gains)))


def db(x):
    return float(20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12))


def separate(sep, model: str, src: Path, out_dir: Path) -> dict:
    sep.output_dir = str(out_dir)
    sep.load_model(model_filename=model)
    files = sep.separate(str(src))
    stems = {}
    for f in files:
        p = Path(f) if os.path.isabs(f) else out_dir / f
        name = p.stem.split("_(")[-1].split(")")[0].lower() if "_(" in p.stem else p.stem.lower()
        # The last "(Stem)" in the name is this pass's stem label.
        label = [part.split(")")[0] for part in p.stem.split("(") if ")" in part][-1].lower()
        audio, sr = sf.read(str(p), always_2d=True)
        assert sr == RATE, f"{p.name} is {sr} Hz"
        stems[label] = audio.astype(np.float64)
    return stems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("audio", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--models", type=Path, required=True, help="folder for the UVR model files")
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("--vocal-model", default=VOCAL_MODEL)
    ap.add_argument("--band-model", default="htdemucs_ft.yaml")
    ap.add_argument("--vocals-only", action="store_true", help="stop after pass 1")
    a = ap.parse_args()

    from audio_separator.separator import Separator
    t0 = time.perf_counter()
    a.out.mkdir(parents=True, exist_ok=True)
    song = decode(a.audio, a.ffmpeg)
    n = len(song)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src = tmp / "input.wav"
        sf.write(str(src), song.astype(np.float32), RATE, subtype="FLOAT")
        sep = Separator(model_file_dir=str(a.models), output_format="WAV", sample_rate=RATE,
                        normalization_threshold=1.0, amplification_threshold=0.0, log_level=40)

        log("[stems] pass 1: separating the vocals (BS-RoFormer)")
        p1 = separate(sep, a.vocal_model, src, tmp / "p1")
        vocals = fit_length(p1.get("vocals"), n)
        inst = fit_length(p1.get("instrumental", p1.get("other")), n)
        fitted, g1 = refit(song, {"vocals": vocals, "instrumental": inst})
        vocals, inst = fitted["vocals"], fitted["instrumental"]
        out = {"vocals": vocals, "instrumental": inst}
        report = {"pass1_gains": g1, "pass1_residual_db": db(song) - db(song - vocals - inst)}

        if not a.vocals_only:
            log("[stems] pass 2: splitting the instrumental (Demucs)")
            ipath = tmp / "instrumental.wav"
            sf.write(str(ipath), inst.astype(np.float32), RATE, subtype="FLOAT")
            p2 = separate(sep, a.band_model, ipath, tmp / "p2")
            band = {k: fit_length(v, n) for k, v in p2.items() if k != "vocals"}
            fitted, g2 = refit(inst, band)
            out.update(fitted)
            report.update({"pass2_gains": g2, "pass2_residual_db": db(inst) - db(inst - sum(fitted.values())),
                           "pass2_vocal_bleed_db": db(fit_length(p2["vocals"], n)) if "vocals" in p2 else None})

    files = []
    for name, audio in out.items():
        path = a.out / f"{name}.wav"
        sf.write(str(path), np.clip(audio, -1, 1).astype(np.float32), RATE, subtype="PCM_24")
        files.append(path.name)
    report.update({"dir": str(a.out), "files": files, "seconds": round(time.perf_counter() - t0, 1),
                   "levels_db": {k: round(db(v), 1) for k, v in out.items()}})
    log(f"[done] {a.out}")
    log("[result] " + json.dumps(report))


if __name__ == "__main__":
    main()
