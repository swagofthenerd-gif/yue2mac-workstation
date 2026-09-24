#!/usr/bin/env python3
"""ACE-Step 1.5 for YuE2Mac (runs in the ACE-Step venv, Apple GPU).

    python acestep_run.py text2music --caption "..." --lyrics-file L.txt --duration 150 --out song.wav
    python acestep_run.py cover      --src SONG.wav --caption "new genre…" --strength 0.5 --out cover.wav
    python acestep_run.py complete   --src VOCALS.wav --tracks drums,bass,guitar,keyboard --caption "…" --out band.wav
    python acestep_run.py lego       --src CONTEXT.wav --track guitar --caption "…" --out guitar.wav
    python acestep_run.py repaint    --src SONG.wav --start 30 --end 45 --caption "…" --out fixed.wav

Covers are driven by the source recording itself: ACE-Step encodes it into its own semantic codes
(melody, rhythm, structure) and regenerates from them with the new caption/lyrics.
  --strength   audio_cover_strength: 1.0 follows the source's structure closely, ~0.2 style transfer
  --cover-noise cover_noise_strength: 0 starts from noise, 1 starts closest to the source audio
complete / lego ("add a band around my vocal", "add a guitar") need an XL Base / Base model.
Models live in the ACE-Step checkout's checkpoints/. Progress `[ace] …`, summary `[result] {json}`.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

ACE = Path.home() / "Library/Application Support/YuE2Mac/ACEStep/src"
sys.path.insert(0, str(ACE))


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("task", choices=("text2music", "cover", "complete", "lego", "repaint"))
    ap.add_argument("--model", help="DiT: acestep-v15-xl-sft (default), acestep-v15-xl-base, acestep-v15-turbo …")
    ap.add_argument("--lm", default="acestep-5Hz-lm-1.7B", help="5 Hz LM for text2music planning (skipped for covers)")
    ap.add_argument("--no-lm", action="store_true")
    ap.add_argument("--caption", required=True)
    ap.add_argument("--lyrics", default="")
    ap.add_argument("--lyrics-file", type=Path)
    ap.add_argument("--instrumental", action="store_true")
    ap.add_argument("--src", type=Path)
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--cover-noise", type=float, default=0.0)
    ap.add_argument("--tracks", default="drums,bass,guitar,keyboard")
    ap.add_argument("--track", default="guitar")
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--end", type=float, default=-1.0)
    ap.add_argument("--duration", type=float, default=-1.0)
    ap.add_argument("--bpm", type=int)
    ap.add_argument("--key", default="")
    ap.add_argument("--language", default="en")
    ap.add_argument("--steps", type=int, help="diffusion steps (SFT/Base default 50, turbo 8)")
    ap.add_argument("--guidance", type=float, help="CFG for non-turbo models")
    ap.add_argument("--seed", type=int, default=-1)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()

    base_tasks = {"complete", "lego"}
    model = a.model or ("acestep-v15-xl-base" if a.task in base_tasks else "acestep-v15-xl-sft")
    if a.task in base_tasks and "base" not in model:
        raise SystemExit(f"'{a.task}' needs a Base model (e.g. acestep-v15-xl-base), not {model}.")
    if a.task != "text2music" and (a.src is None or not a.src.exists()):
        raise SystemExit("This task needs --src audio.")
    lyrics = a.lyrics_file.read_text(encoding="utf-8") if a.lyrics_file else a.lyrics
    if a.instrumental and not lyrics:
        lyrics = "[Instrumental]"

    os.chdir(ACE)
    t0 = time.perf_counter()
    from acestep.handler import AceStepHandler
    from acestep.llm_inference import LLMHandler
    from acestep.inference import GenerationParams, GenerationConfig, generate_music
    from acestep.constants import TASK_INSTRUCTIONS

    log(f"[ace] loading {model}")
    dit = AceStepHandler()
    msg, ok = dit.initialize_service(project_root=str(ACE), config_path=model, device="auto")
    if not ok:
        raise SystemExit(f"Couldn't load {model}: {msg}")
    llm = LLMHandler()
    use_lm = a.task == "text2music" and not a.no_lm
    if use_lm:
        log(f"[ace] loading {a.lm}")
        llm.initialize(checkpoint_dir=str(ACE / "checkpoints"), lm_model_path=a.lm, backend="mlx", device="auto")
    load_s = time.perf_counter() - t0

    instruction = TASK_INSTRUCTIONS.get(a.task, "")
    if a.task == "complete":
        classes = [t.strip().upper() for t in a.tracks.split(",") if t.strip()]
        instruction = TASK_INSTRUCTIONS["complete"].format(TRACK_CLASSES=" | ".join(classes))
    elif a.task == "lego":
        instruction = TASK_INSTRUCTIONS["lego"].format(TRACK_NAME=a.track.upper())

    kw = dict(task_type=a.task, instruction=instruction, caption=a.caption, lyrics=lyrics,
              instrumental=a.instrumental, vocal_language=a.language, duration=a.duration,
              keyscale=a.key, seed=a.seed, thinking=use_lm, use_cot_metas=use_lm,
              use_cot_caption=False, use_cot_language=False)
    if a.bpm:
        kw["bpm"] = a.bpm
    if a.src:
        kw["src_audio"] = str(a.src)
    if a.task == "cover":
        kw.update(audio_cover_strength=a.strength, cover_noise_strength=a.cover_noise)
    if a.task in ("repaint", "lego"):
        kw.update(repainting_start=a.start, repainting_end=a.end)
    if a.steps:
        kw["inference_steps"] = a.steps
    if a.guidance is not None:
        kw["guidance_scale"] = a.guidance
    params = GenerationParams(**kw)
    fixed = a.seed is not None and a.seed >= 0
    config = GenerationConfig(batch_size=1, audio_format="wav", use_random_seed=not fixed,
                              seeds=[a.seed] if fixed else None)

    log(f"[ace] generating ({a.task})")
    t1 = time.perf_counter()
    out_dir = a.out.parent / (a.out.stem + ".parts")
    res = generate_music(dit, llm, params, config, save_dir=str(out_dir))
    if not res.success or not res.audios:
        raise SystemExit(f"ACE-Step failed: {res.error}")
    produced = Path(res.audios[0]["path"])
    a.out.parent.mkdir(parents=True, exist_ok=True)
    produced.replace(a.out)
    gen_s = time.perf_counter() - t1
    meta = {k: res.audios[0].get(k) for k in ("key", "bpm", "duration") if k in res.audios[0]}
    log(f"[done] {a.out}")
    log("[result] " + json.dumps({"file": str(a.out), "task": a.task, "model": model, "load_seconds": round(load_s, 1),
                                  "generate_seconds": round(gen_s, 1), "seed": res.audios[0].get("params", {}).get("seed"),
                                  **meta}, default=str))


if __name__ == "__main__":
    main()
