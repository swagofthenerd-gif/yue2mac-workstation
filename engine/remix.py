#!/usr/bin/env python3
"""Stable Audio 3 for YuE2Mac on the Apple GPU (Stability's official MLX runtime).

    python remix.py restyle STEM.wav --prompt "late-night jazz trio" --strength 0.5 --out out.wav
    python remix.py region  SONG.wav --start 32 --end 40 --prompt "punchy drum fill" --out out.wav
    python remix.py extend  SONG.wav --seconds 30 --prompt "same groove, building" --out out.wav
    python remix.py create  --prompt "warm analog pad, 90 BPM" --seconds 45 --out out.wav
    python remix.py fetch   [--model medium|small-music|small-sfx]

Runs `optimized/mlx/scripts/sa3_mlx.py` from the stable-audio-3 checkout (set up by
scripts/setup_stable_audio3.sh). Medium restyles a whole song (≤ 6:10) in one pass — measured
3:37 in ~14 s on an M2 Ultra; longer inputs, or Small (≤ 1:50), are processed in equal
bar-aligned parts with an equal-power crossfade. Output is 48 kHz and, for restyle/region, the
input's exact length, so it drops back under the other stems.

Strength (init noise level) measured on a full song: ≤ 0.55 stays locked to the original's
timing (rhythm match 0.56–0.81, ~0 ms drift) so it still fits the original vocals; ≥ 0.6 the
rhythm is re-invented (0.04–0.34, up to 244 ms off). Instrumental and sound only — no singing.
Progress: `[remix] …`; summary: `[result] {json}`.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf

OUT_RATE = 48000
MODELS = {  # CLI model name -> (runtime --dit, --decoder, max seconds per pass with headroom)
    "medium": ("medium", "same-l", 370.0),
    "small-music": ("sm-music", "same-s", 110.0),
    "small-sfx": ("sm-sfx", "same-s", 110.0),
}
MLX_DIR = Path.home() / "Library/Application Support/YuE2Mac/StableAudio3/src/optimized/mlx"
FFMPEG = "ffmpeg"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def runtime():
    py, script = MLX_DIR / ".venv/bin/python", MLX_DIR / "scripts/sa3_mlx.py"
    if not py.exists() or not script.exists():
        raise SystemExit("Stable Audio 3 (Mac version) isn't installed. Run scripts/setup_stable_audio3.sh "
                         "or Settings → More models → Remix.")
    return py, script


def sa3(args, label):
    """Run one generation with the MLX runtime; returns audio [n, 2] at 48 kHz."""
    py, script = runtime()
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out.wav"
        env = dict(os.environ)
        env.pop("HF_HUB_OFFLINE", None)   # first use of a model downloads it
        p = subprocess.run([str(py), str(script), *args, "--out", str(out)], cwd=str(MLX_DIR),
                           capture_output=True, text=True, env=env)
        if p.returncode != 0 or not out.exists():
            text = " | ".join([l for l in (p.stderr + p.stdout).splitlines() if l.strip()][-6:])
            if "401" in text or "ated" in text:
                raise SystemExit("Stable Audio 3's download was refused: log in (`hf auth login`) and accept "
                                 "https://huggingface.co/stabilityai/stable-audio-3-optimized")
            raise SystemExit(f"Stable Audio 3 failed ({label}): {text[-500:]}")
        return to48(out)


def to48(path: Path) -> np.ndarray:
    audio, sr = sf.read(str(path), always_2d=True, dtype="float32")
    if audio.shape[1] == 1:
        audio = np.repeat(audio, 2, axis=1)
    if sr == OUT_RATE:
        return audio
    raw = subprocess.run([FFMPEG, "-v", "error", "-f", "f32le", "-ar", str(sr), "-ac", "2", "-i", "-",
                          "-ar", str(OUT_RATE), "-f", "f32le", "-"], input=np.ascontiguousarray(audio).tobytes(),
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, 2).copy()


def to_wav(src: Path, dst: Path, start=None, length=None):
    cmd = [FFMPEG, "-v", "error", "-y", "-nostdin"]
    if start is not None:
        cmd += ["-ss", f"{start:.4f}"]
    cmd += ["-i", str(src)]
    if length is not None:
        cmd += ["-t", f"{length:.4f}"]
    subprocess.run(cmd + ["-ac", "2", "-ar", str(OUT_RATE), "-c:a", "pcm_f32le", str(dst)], check=True)


def seconds_of(path: Path, tmp: Path) -> float:
    try:
        info = sf.info(str(path))
        return info.frames / info.samplerate
    except Exception:  # mp3 / m4a: measure a decoded copy
        w = tmp / "measure.wav"
        to_wav(path, w)
        info = sf.info(str(w))
        return info.frames / info.samplerate


def fit(audio: np.ndarray, n: int) -> np.ndarray:
    audio = audio[:n]
    return np.pad(audio, ((0, n - len(audio)), (0, 0))) if len(audio) < n else audio


def chunk_plan(total_s: float, max_s: float, bpm: float | None, overlap_s: float):
    """Equal parts covering [0, total_s], each ≤ max_s with overlap; joins on bar lines (4/4) when
    the tempo is known, so crossfades land where the music turns over anyway."""
    if total_s <= max_s:
        return [(0.0, total_s)]
    parts = math.ceil((total_s - overlap_s) / (max_s - overlap_s))
    while True:
        length = (total_s - overlap_s) / parts
        if bpm:
            bar = 240.0 / bpm
            length = max(bar, math.ceil(length / bar) * bar)
            while length + overlap_s > max_s and length > bar:
                length -= bar
        if parts * length + overlap_s >= total_s - 1e-6:
            break
        parts += 1
    plan, t = [], 0.0
    while t < total_s - overlap_s - 1e-6:
        plan.append((t, min(total_s - t, length + overlap_s)))
        t += length
    return plan


def common(a, seconds):
    dit, dec, _ = MODELS[a.model]
    args = ["--prompt", a.prompt, "--dit", dit, "--decoder", dec, "--seconds", f"{seconds:.3f}",
            "--steps", str(a.steps), "--cfg", str(a.cfg)]
    if a.negative:
        args += ["--negative-prompt", a.negative]
    if a.seed is not None and a.seed >= 0:
        args += ["--seed", str(a.seed)]
    return args


def cmd_restyle(a, tmp: Path):
    total = seconds_of(a.audio, tmp)
    n = int(round(total * OUT_RATE))
    plan = chunk_plan(total, MODELS[a.model][2], a.bpm, a.overlap)
    out = np.zeros((n, 2), np.float32)
    fade = int(a.overlap * OUT_RATE)
    for i, (start, length) in enumerate(plan):
        log(f"[remix] restyling part {i + 1} of {len(plan)}" if len(plan) > 1 else "[remix] restyling")
        seg = tmp / f"in-{i}.wav"
        chunked = len(plan) > 1
        to_wav(a.audio, seg, start if chunked else None, length if chunked else None)
        y = sa3(common(a, length) + ["--init-audio", str(seg), "--init-noise-level", f"{a.strength:.3f}"],
                f"part {i + 1}")
        s0 = int(round(start * OUT_RATE))
        y = fit(y, min(int(round(length * OUT_RATE)), n - s0))
        if i == 0 or fade == 0:
            out[s0:s0 + len(y)] = y
        else:
            w = (np.sin(np.linspace(0, np.pi / 2, fade)) ** 2)[:, None]
            f = min(fade, len(y))
            out[s0:s0 + f] = out[s0:s0 + f] * (1 - w[:f]) + y[:f] * w[:f]
            out[s0 + f:s0 + len(y)] = y[f:]
    return out, {"parts": len(plan), "seconds": total}


def cmd_region(a, tmp: Path):
    full = tmp / "full.wav"
    to_wav(a.audio, full)
    song, _ = sf.read(str(full), always_2d=True, dtype="float32")
    total = len(song) / OUT_RATE
    limit = MODELS[a.model][2]
    w0, w1 = (0.0, total) if total <= limit else (max(0.0, a.start - 20), min(total, a.end + 20))
    win = tmp / "window.wav"
    to_wav(a.audio, win, w0, w1 - w0)
    log(f"[remix] regenerating {a.start:.1f}s–{a.end:.1f}s")
    y = sa3(common(a, w1 - w0) + ["--init-audio", str(win), "--inpaint-range", f"{a.start - w0:.3f},{a.end - w0:.3f}"],
            "region")
    s0 = int(round(w0 * OUT_RATE))
    y = fit(y, min(int(round((w1 - w0) * OUT_RATE)), len(song) - s0))
    # The model re-encodes the whole window, which colours the untouched parts slightly. Keep the
    # original everywhere except the region and splice the new audio in with 60 ms crossfades.
    new = song.copy()
    new[s0:s0 + len(y)] = y
    r0, r1 = int(round(a.start * OUT_RATE)), int(round(a.end * OUT_RATE))
    f = int(0.06 * OUT_RATE)
    out = song.copy()
    out[r0:r1] = new[r0:r1]
    ramp = (np.sin(np.linspace(0, np.pi / 2, f)) ** 2)[:, None]
    if r0 - f >= 0:
        out[r0 - f:r0] = song[r0 - f:r0] * (1 - ramp) + new[r0 - f:r0] * ramp
    if r1 + f <= len(song):
        out[r1:r1 + f] = new[r1:r1 + f] * (1 - ramp) + song[r1:r1 + f] * ramp
    return out, {"region": [a.start, a.end]}


def cmd_extend(a, tmp: Path):
    full = tmp / "full.wav"
    to_wav(a.audio, full)
    song, _ = sf.read(str(full), always_2d=True, dtype="float32")
    total = len(song) / OUT_RATE
    keep = min(total, MODELS[a.model][2] - a.seconds)
    tail = song[-int(keep * OUT_RATE):]
    padded = np.concatenate([tail, np.zeros((int(a.seconds * OUT_RATE), 2), np.float32)])
    pin = tmp / "padded.wav"
    sf.write(str(pin), padded, OUT_RATE, subtype="FLOAT")
    log(f"[remix] extending by {a.seconds:.0f}s")
    y = sa3(common(a, keep + a.seconds) + ["--init-audio", str(pin),
                                           "--inpaint-range", f"{keep:.3f},{keep + a.seconds:.3f}"], "extend")
    added = y[int(round(keep * OUT_RATE)):]
    return np.concatenate([song, added]), {"added_seconds": len(added) / OUT_RATE}


def cmd_create(a, tmp: Path):
    log(f"[remix] creating {a.seconds:.0f}s")
    y = sa3(common(a, a.seconds), "create")
    return y, {"seconds": len(y) / OUT_RATE}


def main():
    global FFMPEG
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("restyle", "region", "extend", "create", "fetch"))
    ap.add_argument("audio", type=Path, nargs="?")
    ap.add_argument("--model", default="medium", choices=tuple(MODELS))
    ap.add_argument("--prompt", default="")
    ap.add_argument("--negative", default="")
    ap.add_argument("--strength", type=float, default=0.5, help="restyle: ≤0.55 keeps the timing; higher reinvents")
    ap.add_argument("--start", type=float)
    ap.add_argument("--end", type=float)
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--bpm", type=float, help="restyle: align chunk joins to bars (only long inputs are chunked)")
    ap.add_argument("--overlap", type=float, default=2.0)
    ap.add_argument("--steps", type=int, default=8, help="the released models are tuned for 8")
    ap.add_argument("--cfg", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=-1)
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    FFMPEG = a.ffmpeg

    if a.mode == "fetch":
        a.prompt = "a short test tone"
        sa3(common(a, 2.0), "download")
        log("[result] " + json.dumps({"ok": True, "model": a.model}))
        return
    if a.mode != "create" and (a.audio is None or not a.audio.exists()):
        raise SystemExit("Give an audio file to work on.")
    if a.mode == "region" and (a.start is None or a.end is None or a.end <= a.start):
        raise SystemExit("Region needs --start and --end (seconds), end after start.")
    if not a.prompt.strip():
        raise SystemExit("Describe the sound you want (--prompt).")
    t0 = time.perf_counter()
    with tempfile.TemporaryDirectory() as tmp:
        audio, info = {"restyle": cmd_restyle, "region": cmd_region, "extend": cmd_extend,
                       "create": cmd_create}[a.mode](a, Path(tmp))
    a.out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(a.out), np.clip(audio, -1, 1), OUT_RATE, subtype="PCM_24")
    log(f"[done] {a.out}")
    log("[result] " + json.dumps({"file": str(a.out), "mode": a.mode, "model": a.model, "device": "Apple GPU (MLX)",
                                  "seconds_taken": round(time.perf_counter() - t0, 1), **info}))


if __name__ == "__main__":
    main()
