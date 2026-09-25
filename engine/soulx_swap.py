#!/usr/bin/env python3
"""Re-sing a vocal in another voice with SoulX-Singer-SVC (run in the SoulX venv).

    python soulx_swap.py VOCALS.wav VOICE_SAMPLE.wav --out SWAPPED.wav [--shift 0|12|-12] [--steps 32] [--cfg 3]

SoulX-Singer-SVC (Soul-AILab, Apache-2.0, 2026) is a zero-shot singing voice converter fine-tuned
from a 42k-hour singing synthesis model; it transfers the prompt singer's timbre *and style*
while keeping the source's melody, rhythm and words. Installed by scripts/setup_soulx.sh.

Pitch for both files comes from RMVPE (the model's own extractor). The model's --auto_shift moves
the melody by any number of semitones, which would put the vocal out of key with the band, so
only whole-octave shifts are offered. Output is the model's native 24 kHz, resampled to the source
vocal's rate, re-aligned and level-matched so it drops back onto the band (vocal_mix.py). Note
24 kHz carries nothing above 12 kHz. Summary: `[result] {json}`. Only use voices you may use.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from scipy.signal import correlate, resample_poly


def soulx_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/YuE2Mac/SoulX"
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "YuE2Mac/SoulX"


def envelope(x: np.ndarray, hop: int) -> np.ndarray:
    return np.sqrt(np.convolve(x.mean(axis=1) ** 2, np.ones(hop) / hop, "same")[::hop])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vocals", type=Path)
    ap.add_argument("voice_sample", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--shift", type=int, default=0, choices=(-12, 0, 12))
    ap.add_argument("--steps", type=int, default=32)
    ap.add_argument("--cfg", type=float, default=3.0)
    a = ap.parse_args()

    root = soulx_dir() / "src"
    os.environ.setdefault("HF_HOME", str(soulx_dir() / "hf"))
    sys.path.insert(0, str(root))
    os.chdir(root)
    from cli.inference_svc import build_model
    from preprocess.tools.f0_extraction import F0Extractor
    from soulxsinger.utils.audio_utils import load_wav
    from soulxsinger.utils.file_utils import load_config

    device = "cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
    config = load_config("soulxsinger/config/soulxsinger.yaml")
    sr_model = config.audio.sample_rate
    with tempfile.TemporaryDirectory() as tmp:
        # The model and RMVPE read 24 kHz / 16 kHz mono themselves; give them mono files.
        paths = {}
        for name, src in (("prompt", a.voice_sample), ("target", a.vocals)):
            x, sr = sf.read(src, always_2d=True)
            paths[name] = f"{tmp}/{name}.wav"
            sf.write(paths[name], x.mean(axis=1), sr)
        f0x = F0Extractor("pretrained_models/SoulX-Singer-Preprocess/rmvpe/rmvpe.pt", device=device)
        pt_f0 = f0x.process(paths["prompt"])
        gt_f0 = f0x.process(paths["target"])
        del f0x
        model = build_model("pretrained_models/SoulX-Singer/model-svc.pt", config, device=device)
        with torch.no_grad():
            wav, _ = model.infer(
                pt_wav=load_wav(paths["prompt"], sr_model).to(device),
                gt_wav=load_wav(paths["target"], sr_model).to(device),
                pt_f0=torch.from_numpy(np.asarray(pt_f0, dtype=np.float32)).unsqueeze(0).to(device),
                gt_f0=torch.from_numpy(np.asarray(gt_f0, dtype=np.float32)).unsqueeze(0).to(device),
                auto_shift=False, pitch_shift=a.shift, n_steps=a.steps, cfg=a.cfg, use_fp16=False)
        vc = wav.squeeze().float().cpu().numpy()[:, None]

    orig, sr = sf.read(a.vocals, always_2d=True)
    g = np.gcd(sr, sr_model)
    vc = resample_poly(vc, sr // g, sr_model // g, axis=0)
    hop = sr // 100
    e1, e2 = envelope(orig, hop), envelope(vc, hop)
    n = min(len(e1), len(e2))
    lag = int((np.argmax(correlate(e2[:n] - e2[:n].mean(), e1[:n] - e1[:n].mean(), "full")) - (n - 1)) * hop)
    vc = vc[lag:] if lag > 0 else np.vstack([np.zeros((-lag, 1)), vc])
    vc = np.vstack([vc[: len(orig)], np.zeros((max(0, len(orig) - len(vc)), 1))])
    vc = np.repeat(vc, orig.shape[1], axis=1)
    vc *= np.sqrt((orig ** 2).mean() / ((vc ** 2).mean() + 1e-12))
    a.out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(a.out, vc.astype(np.float32), sr, subtype="FLOAT")
    print("[result] " + json.dumps({"out": str(a.out), "shift": a.shift, "offset_ms": round(lag / sr * 1000, 1),
                                    "device": device}), flush=True)


if __name__ == "__main__":
    main()
