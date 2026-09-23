#!/usr/bin/env python3
"""Stable Audio 3 for YuE2Mac: restyle, regenerate a region, extend, or create (SA3 venv).

    python remix.py restyle STEM.wav --prompt "glitchy granular IDM textures" --strength 0.6 --out out.wav
    python remix.py region  SONG.wav --start 32 --end 40 --prompt "punchy drum fill" --out out.wav
    python remix.py extend  SONG.wav --seconds 30 --prompt "same groove, building" --out out.wav
    python remix.py create  --prompt "warm analog pad, 90 BPM" --seconds 45 --out out.wav
    python remix.py fetch   [--model small-music]          # one-time download (needs HF login)

Instrumental and sound only — Stable Audio 3 doesn't sing. Restyle keeps the stem locked to
the song: long inputs are processed in chunks (bar-aligned when --bpm is given) with the
same seed and an equal-power crossfade, and the result is exactly the input's length at
48 kHz so it drops back under the other stems. Lower --strength stays closer to the
original's timing and notes; 0.8+ reinvents more but can drift off the grid.
Progress: `[remix] …`; summary: `[result] {json}`.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

OUT_RATE = 48000
MAX_SECONDS = {"small-music": 110.0, "small-sfx": 110.0, "medium": 360.0}  # headroom under 120 / 380


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def decode(path: Path, ffmpeg: str, rate: int):
    import numpy as np
    raw = subprocess.run([ffmpeg, "-v", "error", "-nostdin", "-i", str(path), "-ac", "2", "-ar", str(rate),
                          "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, 2).T.copy()   # [2, samples]


def load_model(name: str):
    try:
        from stable_audio_3 import StableAudioModel
        return StableAudioModel.from_pretrained(name)
    except Exception as exc:  # gated download, missing login, missing weights
        msg = str(exc)
        if any(k in msg for k in ("401", "403", "gated", "Unauthorized", "restricted", "LocalEntryNotFound", "offline")):
            raise SystemExit(
                "Stable Audio 3 isn't downloaded yet. On huggingface.co, accept the licenses for "
                "stabilityai/stable-audio-3-" + name + " and google/t5gemma-b-b-ul2, run "
                "`hf auth login`, then Settings → Install Remix (or: remix.py fetch).")
        raise


def to_out(audio, rate):
    """Model output [2, n] at the model's rate → numpy [2, n] at 48 kHz."""
    import torch
    import torchaudio.functional as AF
    x = audio.float().cpu()
    if rate != OUT_RATE:
        x = AF.resample(x, rate, OUT_RATE)
    return x.numpy()


def generate(model, **kw):
    import torch
    with torch.inference_mode():
        return model.generate(**kw)[0]


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


def cmd_restyle(a, model):
    import numpy as np
    import torch
    rate = model.model.sample_rate
    src = decode(a.audio, a.ffmpeg, rate)
    total = src.shape[1] / rate
    plan = chunk_plan(total, MAX_SECONDS.get(a.model, 110.0), a.bpm, a.overlap)
    n_out = int(round(total * OUT_RATE))
    out = np.zeros((2, n_out), np.float32)
    fade = int(a.overlap * OUT_RATE)
    for i, (start, length) in enumerate(plan):
        log(f"[remix] restyling part {i + 1} of {len(plan)} ({start:.0f}s–{start + length:.0f}s)")
        seg = torch.from_numpy(src[:, int(start * rate):int((start + length) * rate)])
        y = to_out(generate(model, prompt=a.prompt, negative_prompt=a.negative or None, duration=length,
                            steps=a.steps, cfg_scale=a.cfg, seed=a.seed, init_audio=(rate, seg),
                            init_noise_level=a.strength), rate)
        s0 = int(round(start * OUT_RATE))
        y = y[:, :n_out - s0]
        if i == 0 or fade == 0:
            out[:, s0:s0 + y.shape[1]] = y
        else:
            w = np.sin(np.linspace(0, np.pi / 2, fade)) ** 2
            f = min(fade, y.shape[1])
            out[:, s0:s0 + f] = out[:, s0:s0 + f] * (1 - w[:f]) + y[:, :f] * w[:f]
            out[:, s0 + f:s0 + y.shape[1]] = y[:, f:]
    return out, {"parts": len(plan), "seconds": total}


def cmd_region(a, model):
    import numpy as np
    import torch
    rate = model.model.sample_rate
    src = decode(a.audio, a.ffmpeg, rate)
    total = src.shape[1] / rate
    if total > MAX_SECONDS.get(a.model, 110.0):
        # Work on a window around the region; splice the result back into the full song.
        pad = 20.0
        w0, w1 = max(0.0, a.start - pad), min(total, a.end + pad)
    else:
        w0, w1 = 0.0, total
    seg = torch.from_numpy(src[:, int(w0 * rate):int(w1 * rate)])
    log(f"[remix] regenerating {a.start:.1f}s–{a.end:.1f}s")
    y = to_out(generate(model, prompt=a.prompt, negative_prompt=a.negative or None, duration=w1 - w0,
                        steps=a.steps, cfg_scale=a.cfg, seed=a.seed, inpaint_audio=(rate, seg),
                        inpaint_mask_start_seconds=a.start - w0, inpaint_mask_end_seconds=a.end - w0), rate)
    full = to_out(torch.from_numpy(src), rate)
    s0 = int(round(w0 * OUT_RATE))
    full[:, s0:s0 + y.shape[1]] = y[:, :full.shape[1] - s0]
    return full, {"region": [a.start, a.end]}


def cmd_extend(a, model):
    import numpy as np
    import torch
    rate = model.model.sample_rate
    src = decode(a.audio, a.ffmpeg, rate)
    keep = min(src.shape[1] / rate, MAX_SECONDS.get(a.model, 110.0) - a.seconds)
    tail = src[:, -int(keep * rate):]
    padded = np.concatenate([tail, np.zeros((2, int(a.seconds * rate)), np.float32)], axis=1)
    log(f"[remix] extending by {a.seconds:.0f}s")
    y = to_out(generate(model, prompt=a.prompt, negative_prompt=a.negative or None, duration=keep + a.seconds,
                        steps=a.steps, cfg_scale=a.cfg, seed=a.seed, inpaint_audio=(rate, torch.from_numpy(padded)),
                        inpaint_mask_start_seconds=keep, inpaint_mask_end_seconds=keep + a.seconds), rate)
    head = to_out(torch.from_numpy(src), rate)
    added = y[:, int(round(keep * OUT_RATE)):]
    return np.concatenate([head, added], axis=1), {"added_seconds": added.shape[1] / OUT_RATE}


def cmd_create(a, model):
    log(f"[remix] creating {a.seconds:.0f}s")
    y = to_out(generate(model, prompt=a.prompt, negative_prompt=a.negative or None, duration=a.seconds,
                        steps=a.steps, cfg_scale=a.cfg, seed=a.seed), model.model.sample_rate)
    return y, {"seconds": y.shape[1] / OUT_RATE}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("restyle", "region", "extend", "create", "fetch"))
    ap.add_argument("audio", type=Path, nargs="?")
    ap.add_argument("--model", default="small-music", choices=("small-music", "small-sfx", "medium"))
    ap.add_argument("--prompt", default="")
    ap.add_argument("--negative", default="")
    ap.add_argument("--strength", type=float, default=0.6, help="restyle: 0.1 subtle … 1.0 reinvent")
    ap.add_argument("--start", type=float)
    ap.add_argument("--end", type=float)
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--bpm", type=float, help="restyle: align chunk joins to bars")
    ap.add_argument("--overlap", type=float, default=2.0)
    ap.add_argument("--steps", type=int, default=8, help="the released models are tuned for 8")
    ap.add_argument("--cfg", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=-1)
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()

    if a.mode == "fetch":
        os.environ.pop("HF_HUB_OFFLINE", None)
        load_model(a.model)
        log("[result] " + json.dumps({"ok": True, "model": a.model}))
        return
    if a.mode != "create" and (a.audio is None or not a.audio.exists()):
        raise SystemExit("Give an audio file to work on.")
    if a.mode == "region" and (a.start is None or a.end is None or a.end <= a.start):
        raise SystemExit("Region needs --start and --end (seconds), end after start.")
    if not a.prompt.strip():
        raise SystemExit("Describe the sound you want (--prompt).")
    t0 = time.perf_counter()
    model = load_model(a.model)
    log(f"[remix] model loaded on {model.device}")
    audio, info = {"restyle": cmd_restyle, "region": cmd_region, "extend": cmd_extend,
                   "create": cmd_create}[a.mode](a, model)
    import numpy as np
    import soundfile as sf
    a.out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(a.out), np.clip(audio.T, -1, 1), OUT_RATE, subtype="PCM_24")
    log(f"[done] {a.out}")
    log("[result] " + json.dumps({"file": str(a.out), "mode": a.mode, "model": a.model,
                                  "device": str(model.device), "seconds_taken": round(time.perf_counter() - t0, 1),
                                  **info}))


if __name__ == "__main__":
    main()
