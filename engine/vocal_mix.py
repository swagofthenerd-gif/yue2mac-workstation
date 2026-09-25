#!/usr/bin/env python3
"""Give a generated song a real vocal mix (Separator venv; needs `pedalboard`).

    python vocal_mix.py VOCALS.wav INSTRUMENTAL.wav --out MIXED.wav [--amount light|full] [--vocal-db 0]

Generated songs come out as a rough, unmixed demo: a dry, flat voice sitting on the band. This
splits nothing itself (use stems.py --vocals-only first) and runs the classic studio chain on
the voice, then puts it back on the band:

  voice : rumble cut → de-mud → compressor → presence + air → de-esser
  sends : plate reverb (pre-delayed, filtered) and a tempo-synced stereo echo for depth/width
  band  : a small dip where the voice's presence lives, so the two don't fight
  bus   : gentle glue compression, then plain gain down to a -1 dBFS peak (no limiter)

Thresholds follow each track's own level, so any song works. "light" is a subtle polish,
"full" a produced, spacious pop/rock vocal. The mix keeps the song's vocal/band balance
(shift it with --vocal-db). Summary: `[result] {json}`.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from pedalboard import (Chorus, Compressor, Delay, Gain, HighpassFilter, HighShelfFilter,
                        LowpassFilter, PeakFilter, Pedalboard, Reverb)

AMOUNTS = {
    #          comp ratio, presence dB, air dB, reverb dB, echo dB, doubler dB, glue ratio
    "light": dict(ratio=2.5, presence=1.5, air=1.5, reverb=-18, echo=-24, double=None, glue=1.3),
    "full":  dict(ratio=3.5, presence=2.5, air=3.0, reverb=-13, echo=-19, double=-15, glue=1.8),
}


def active_db(x: np.ndarray, sr: int) -> float:
    """Level of the parts that actually sound (400 ms blocks above -50 dBFS), in dBFS RMS."""
    m = x.mean(axis=1) if x.ndim > 1 else x
    blk = int(0.4 * sr)
    rms = np.array([np.sqrt(np.mean(m[i:i + blk] ** 2)) for i in range(0, len(m) - blk, blk)])
    rms = rms[rms > 10 ** (-50 / 20)]
    return float(20 * np.log10(np.sqrt(np.mean(rms ** 2)) + 1e-12)) if len(rms) else -60.0


def tempo(x: np.ndarray, sr: int) -> float:
    try:
        import librosa
        bpm = float(np.atleast_1d(librosa.beat.beat_track(y=x.mean(axis=1)[: sr * 90], sr=sr)[0])[0])
        return bpm if 60 <= bpm <= 200 else 100.0
    except Exception:
        return 100.0


def run(board: Pedalboard, x: np.ndarray, sr: int) -> np.ndarray:
    return board(x.T.astype(np.float32), sr).T


def de_ess(x: np.ndarray, sr: int, level_db: float) -> np.ndarray:
    """Split-band de-esser: compress only the band above 6 kHz; low + high rebuilds x exactly."""
    high = run(Pedalboard([HighpassFilter(6000)]), x, sr)
    low = x - high
    tamed = run(Pedalboard([Compressor(threshold_db=level_db - 14, ratio=4, attack_ms=1, release_ms=60)]), high, sr)
    return low + tamed


def mono_to_stereo(x: np.ndarray) -> np.ndarray:
    return np.repeat(x, 2, axis=1) if x.shape[1] == 1 else x


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vocals", type=Path)
    ap.add_argument("instrumental", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--amount", default="full", choices=AMOUNTS)
    ap.add_argument("--vocal-db", type=float, default=0.0, help="voice level vs the song's own balance")
    a = ap.parse_args()
    p = AMOUNTS[a.amount]

    v, sr = sf.read(a.vocals, always_2d=True, dtype="float32")
    b, sr_b = sf.read(a.instrumental, always_2d=True, dtype="float32")
    if sr != sr_b:
        raise SystemExit("vocals and instrumental must share a sample rate")
    n = min(len(v), len(b))
    v, b = mono_to_stereo(v[:n]), mono_to_stereo(b[:n])
    v_level, b_level = active_db(v, sr), active_db(b, sr)
    bpm = tempo(b, sr)
    beat = 60.0 / bpm

    # Voice: clean up, control, brighten, then tame the esses the brightening brings out.
    voice = run(Pedalboard([
        HighpassFilter(90),
        PeakFilter(300, gain_db=-2.5, q=1.0),
        Compressor(threshold_db=v_level - 4, ratio=p["ratio"], attack_ms=5, release_ms=90),
        PeakFilter(3500, gain_db=p["presence"], q=0.8),
        HighShelfFilter(10000, gain_db=p["air"]),
    ]), v, sr)
    voice *= 10 ** ((v_level - active_db(voice, sr)) / 20)          # compressor has no make-up gain
    voice = de_ess(voice, sr, active_db(voice, sr))

    # Sends: a pre-delayed plate for depth, a stereo echo (1/8 left, 1/4 right) for width.
    pre = int(0.025 * sr)
    rv_in = np.vstack([np.zeros((pre, 2), np.float32), voice])[:n]
    reverb = run(Pedalboard([
        Reverb(room_size=0.55, damping=0.5, wet_level=1.0, dry_level=0.0, width=1.0),
        HighpassFilter(250), LowpassFilter(8000), Gain(p["reverb"]),
    ]), rv_in, sr)
    echo_l = run(Pedalboard([Delay(beat / 2, feedback=0.25, mix=1.0)]), voice[:, :1], sr)
    echo_r = run(Pedalboard([Delay(beat, feedback=0.2, mix=1.0)]), voice[:, 1:], sr)
    echo = run(Pedalboard([HighpassFilter(300), LowpassFilter(5000), Gain(p["echo"])]),
               np.hstack([echo_l, echo_r]), sr)
    sends = reverb + echo
    if p["double"] is not None:                                      # subtle widening doubler
        sends += run(Pedalboard([Chorus(rate_hz=0.6, depth=0.15, centre_delay_ms=14, feedback=0.0, mix=1.0),
                                 HighpassFilter(200), Gain(p["double"])]), voice, sr)

    # Band: make a little room where the voice's presence lives.
    band = run(Pedalboard([PeakFilter(3000, gain_db=-1.5, q=1.0)]), b, sr)

    mix = band + (voice + sends) * 10 ** (a.vocal_db / 20)
    mix_level = active_db(mix, sr)
    mix = run(Pedalboard([
        Compressor(threshold_db=mix_level - 2, ratio=p["glue"], attack_ms=30, release_ms=200),
    ]), mix, sr)
    mix *= 10 ** ((mix_level - active_db(mix, sr)) / 20)
    # Ceiling by plain gain, never a limiter: generated songs arrive up to 2.5x over full scale, and
    # limiting that much flattened the mix by ~7 dB of punch.
    peak = float(np.abs(mix).max())
    if peak > 10 ** (-1 / 20):
        mix *= 10 ** (-1 / 20) / peak
    a.out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(a.out, mix, sr, subtype="PCM_24")
    print("[result] " + json.dumps({"out": str(a.out), "amount": a.amount, "bpm": round(bpm, 1),
                                    "vocal_dbfs": round(v_level, 1), "band_dbfs": round(b_level, 1)}), flush=True)


if __name__ == "__main__":
    sys.exit(main())
