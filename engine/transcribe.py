#!/usr/bin/env python3
"""Audio -> ABC score with SheetSage2, for YuE2Mac's cover mode.

Runs in SheetSage2's own Python environment (it pins older torch/numpy than the
MLX engine). Any format ffmpeg reads is converted to 24 kHz mono first, so no
FFmpeg shared libraries are needed inside Python. Both models load from local
folders: nothing is fetched at run time.

Prints `[transcribe] ...` progress and a final `[result] {json}` line to stderr.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

SAMPLE_RATE = 24000


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def load_audio(path: Path, ffmpeg: str, start: float | None, duration: float | None):
    import numpy as np
    cmd = [ffmpeg, "-v", "error", "-nostdin"]
    if start:
        cmd += ["-ss", str(start)]
    cmd += ["-i", str(path)]
    if duration:
        cmd += ["-t", str(duration)]
    cmd += ["-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "-"]
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("audio", type=Path)
    ap.add_argument("--models", type=Path, required=True, help="folder with SheetSage2/ and MERT-v2-FullSong/")
    ap.add_argument("--output", type=Path, required=True, help="folder for score.abc, MIDI and events")
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("--device", default="auto", choices=("auto", "mps", "cpu"))
    ap.add_argument("--with-chords", action="store_true", help="keep chord symbols (for a full-mode cover)")
    ap.add_argument("--start", type=float, help="seconds into the file to start")
    ap.add_argument("--duration", type=float, help="seconds of audio to use")
    a = ap.parse_args()

    import os
    import shutil
    # Keep remote-code modules beside the models, and pre-copy every code file:
    # transformers 4.45 misses nested relative imports (exports -> chord_spelling)
    # when it stages a local model's code on its own.
    cache = a.models / "modules"
    os.environ["HF_MODULES_CACHE"] = str(cache)
    for name in ("SheetSage2", "MERT-v2-FullSong"):
        dest = cache / "transformers_modules" / name.replace("-", "_hyphen_")
        dest.mkdir(parents=True, exist_ok=True)
        for src in (a.models / name).glob("*.py"):
            shutil.copy2(src, dest / src.name)
        (dest / "__init__.py").touch()

    import torch
    from transformers import AutoModel

    device = a.device
    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    t0 = time.perf_counter()
    log("[transcribe] reading audio")
    audio = load_audio(a.audio, a.ffmpeg, a.start, a.duration)
    if audio.size < 1025:
        raise SystemExit("That audio is too short to transcribe.")
    log(f"[transcribe] loading SheetSage2 on {device}")
    model = AutoModel.from_pretrained(
        str(a.models / "SheetSage2"), base_model_path=str(a.models / "MERT-v2-FullSong"),
        local_files_only=True, trust_remote_code=True,
    ).eval().to(device)
    load_s = time.perf_counter() - t0

    def progress(v):
        if v.get("stage") == "encoding":
            log(f"[transcribe] window {v['window']}/{v['windows']}")

    t1 = time.perf_counter()
    res = model.transcribe(audio, sampling_rate=SAMPLE_RATE, output_dir=str(a.output),
                           dtype="fp32", melody_only=not a.with_chords, progress=progress)
    abc = res.get("abc")
    if not abc:
        raise SystemExit(f"SheetSage2 produced no score: {res.get('abc_error') or 'unknown reason'}")
    a.output.mkdir(parents=True, exist_ok=True)
    (a.output / "score.abc").write_text(abc, encoding="utf-8")
    log(f"[done] {a.output / 'score.abc'}")
    log("[result] " + json.dumps({
        "abc_file": str(a.output / "score.abc"), "device": device, "with_chords": a.with_chords,
        "audio_seconds": audio.size / SAMPLE_RATE, "load_seconds": load_s,
        "transcribe_seconds": time.perf_counter() - t1,
        "files": sorted(p.name for p in a.output.iterdir()),
    }))


if __name__ == "__main__":
    main()
