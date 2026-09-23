#!/usr/bin/env python3
"""YuE2Mac workstation engine — drives the downloaded MLX port without modifying it.

The app runs this instead of calling `generate.py` directly. It imports the port's
building blocks (tokenizer, AR sampler, flow-matching synthesis, VAE) and exposes
every control the model has, stage by stage:

    generate   score plan (optional) -> semantic tokens -> acoustic latents -> audio
    plan       score only, so it can be reviewed or edited before any audio work
    decode     re-render audio from saved latents
    abc        score tools: inspect, strip-chords, set-tempo, compare, fit-length

Progress goes to stderr in the port's own `[plan]/[semantic]/[nar]/[vae]/[done]`
format so older app builds keep parsing it; the final machine-readable summary is a
single `[result] {json}` line.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import time
from dataclasses import asdict, replace
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import abc_tools  # noqa: E402  (official YuE2 skill helper, standard library only)

TOKENS_PER_SECOND = 25          # one codec frame = 40 ms
HARD_TOKEN_CAP = 9000           # the model's own semantic max_tokens
CHORD_SYMBOL = re.compile(r'"[A-G][^"\n]*"')
TEMPO_LINE = re.compile(r"^Q:\s*1/4\s*=\s*\d+\s*$", re.MULTILINE)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def result(payload):
    log("[result] " + json.dumps(payload, default=str))


# ── Score helpers (no model needed) ─────────────────────────────────────────

def has_chords(abc_text: str) -> bool:
    """True when a music line carries a quoted chord symbol (header voice names don't count)."""
    music = [l for l in abc_text.splitlines() if not re.match(r"^[A-Za-z]:|^V:|^%", l.strip())]
    return any(CHORD_SYMBOL.search(l) for l in music)


def set_tempo(abc_text: str, bpm: int) -> str:
    if not 20 <= bpm <= 300:
        raise ValueError("Tempo must be between 20 and 300 BPM")
    line = f"Q:1/4={bpm}"
    if TEMPO_LINE.search(abc_text):
        return TEMPO_LINE.sub(line, abc_text, count=1)
    # No tempo header: insert it before the key line, which ends the ABC header.
    return re.sub(r"^(K:.*)$", line + r"\n\1", abc_text, count=1, flags=re.MULTILINE)


def score_seconds(abc_text: str):
    try:
        return abc_tools.report(abc_tools.parse_abc(abc_text))["nominal_duration_seconds"]
    except Exception:
        return None


def fit_tokens(abc_text: str, fallback: int) -> tuple[int, str]:
    """Token budget that fits the score's length, leaving room for an ending."""
    seconds = score_seconds(abc_text)
    if seconds is None:
        return min(fallback, HARD_TOKEN_CAP), "score could not be measured; using the manual length"
    tokens = int(math.ceil(seconds * TOKENS_PER_SECOND * 1.15)) + 250
    capped = min(tokens, HARD_TOKEN_CAP)
    note = f"score is {seconds:.0f}s -> {capped} tokens"
    if capped < tokens:
        note += f" (capped at {HARD_TOKEN_CAP}; the score is longer than the model's 6-minute limit)"
    return capped, note


def check_score(abc_text: str) -> dict:
    try:
        rep = abc_tools.report(abc_tools.parse_abc(abc_text))
        return {"ok": True, "bpm": rep["bpm"], "seconds": rep["nominal_duration_seconds"],
                "chords": has_chords(abc_text)}
    except Exception as exc:  # outside the native dialect, or a truncated plan
        return {"ok": False, "error": str(exc), "chords": has_chords(abc_text)}


# ── Model-backed stages ─────────────────────────────────────────────────────

class Engine:
    def __init__(self, scripts: Path, model: Path):
        sys.path.insert(0, str(scripts))
        import generate as g  # the port's module; never edited
        self.g = g
        self.model_dir = model
        t0 = time.perf_counter()
        self.pipe = g.Yue2Pipeline(model, log=log)
        self.load_seconds = time.perf_counter() - t0

    def sampling(self, base, a, prefix):
        """Copy a stage's Sampling with any user overrides (flags named <prefix>temperature etc.)."""
        over = {}
        for field in ("temperature", "top_p", "top_k", "repetition_penalty", "penalty_window"):
            v = getattr(a, prefix + field, None)
            if v is not None:
                over[field] = v
        return replace(base, **over)

    def plan(self, style, lyrics, cot, seed, abc_sampling):
        g, tok = self.g, self.pipe.tokenizer
        log("[plan] generating ABC score")
        ids, truncated = g.generate_tokens(self.pipe.model, g.token_prefix(tok, style, lyrics, cot),
                                           abc_sampling, seed, "abc",
                                           on_token=self.pipe._progress("abc"))
        if truncated:
            log("[plan] ABC hit max_tokens")
        return ids, tok.decode(ids), truncated

    def song(self, style, lyrics, cot, seed, abc_ids, sem_sampling, cfg_scale, steps, on_latents=None):
        """Semantic -> latents -> audio for a fixed plan. Mirrors Yue2Pipeline.__call__."""
        g, tok = self.g, self.pipe.tokenizer
        prefix = g.token_prefix(tok, style, lyrics, cot, abc_ids)
        guidance = (1.01 if cot == "off" else 1.0) if cfg_scale is None else cfg_scale
        negative = g.negative_prefix(tok, cot, abc_ids) if guidance != 1 else None
        if len(prefix) + sem_sampling.max_tokens > g.CONTEXT:
            room = g.CONTEXT - len(prefix)
            log(f"[semantic] length trimmed to {room} tokens to fit the model's context")
            sem_sampling = replace(sem_sampling, max_tokens=room, min_tokens=min(sem_sampling.min_tokens, room))
        log(f"[semantic] prefix {len(prefix)} tokens, cfg {guidance}")
        times = {}
        t = time.perf_counter()
        ids, truncated = g.generate_tokens(self.pipe.model, prefix, sem_sampling, seed, "semantic",
                                           negative, guidance, legacy_off=cot == "off",
                                           on_token=self.pipe._progress("semantic"))
        times["semantic"] = time.perf_counter() - t
        if truncated:
            log("[semantic] hit max_tokens")
        codec = [x - g.CODEC_OFFSET for x in ids]
        if not codec:
            raise RuntimeError("Semantic stage produced no codec tokens")
        n = steps or self.pipe.ode_steps
        log(f"[nar] {len(codec)} frames ({len(codec) * 1920 / g.SAMPLE_RATE:.1f}s), {n} midpoint steps")
        t = time.perf_counter()
        latents = g.synthesize(self.pipe.model, prefix, codec, seed, n,
                               on_progress=lambda i, total: i % 4 == 0 and log(f"[nar] step {i}/{total}"))
        times["nar"] = time.perf_counter() - t
        if on_latents:
            on_latents(latents)
        log("[vae] decoding")
        t = time.perf_counter()
        audio = self.pipe.decode(latents)
        times["vae"] = time.perf_counter() - t
        return audio, {"guidance": guidance, "semantic_tokens": len(codec), "semantic_truncated": truncated,
                       "seconds": len(codec) * 1920 / g.SAMPLE_RATE, "timings": times}


def seeds_for(a):
    import random
    if a.seeds:
        return [int(s) for s in a.seeds.split(",") if s.strip()]
    first = a.seed if a.seed is not None else random.randint(0, 999_999)
    return [first + i for i in range(a.takes)]


def cmd_generate(a):
    import numpy as np
    style = a.style
    lyrics = a.lyrics if a.lyrics is not None else a.lyrics_file.read_text(encoding="utf-8")
    out = a.out_dir
    out.mkdir(parents=True, exist_ok=True)
    abc_text = a.abc_file.read_text(encoding="utf-8") if a.abc_file else None
    cot = a.cot
    notes = []

    if abc_text is not None:
        if a.tempo:
            abc_text = set_tempo(abc_text, a.tempo)
            notes.append(f"tempo set to {a.tempo} BPM")
        if a.keep_voice != "both" or a.strip_chords:
            abc_text = abc_tools.strip_chords(abc_text, keep_voice=a.keep_voice)
            notes.append("chords removed" + (f", kept only {a.keep_voice}" if a.keep_voice != "both" else ""))
        if cot == "auto":
            cot = "full" if has_chords(abc_text) else "melody"
            notes.append(f"planning set to {cot} ({'score has chords' if cot == 'full' else 'melody-only score'})")
        elif cot == "off":
            raise SystemExit("A score can't be used with planning Off; choose full, melody or auto.")
    elif cot == "auto":
        cot = "full"

    eng = Engine(a.scripts, a.model)
    abc_s = eng.sampling(eng.pipe.abc_sampling, a, "plan_")
    sem_s = eng.sampling(eng.pipe.semantic_sampling, a, "")
    manual_tokens = min(a.max_tokens or sem_s.max_tokens, HARD_TOKEN_CAP)
    tok = eng.pipe.tokenizer
    seeds = seeds_for(a)

    # One plan shared by every take, so takes are new performances of the same song.
    plan_truncated = False
    abc_ids = []
    if cot != "off":
        if abc_text is None:
            abc_ids, abc_text, plan_truncated = eng.plan(style, lyrics, cot, seeds[0], abc_s)
        else:
            abc_ids = tok.encode(abc_text)
        (out / "score.abc").write_text(abc_text, encoding="utf-8")
    if a.auto_length and abc_text is not None:
        tokens, why = fit_tokens(abc_text, manual_tokens)
        notes.append("length: " + why)
    else:
        tokens = manual_tokens
    sem_s = replace(sem_s, max_tokens=tokens, min_tokens=min(sem_s.min_tokens, tokens))
    for n in notes:
        log(f"[note] {n}")

    takes = []
    for i, seed in enumerate(seeds, 1):
        name = f"take-{i}" if len(seeds) > 1 else "song"
        log(f"[take] {i}/{len(seeds)} seed {seed}")
        latents_path = out / f"{name}.latents.npy"
        audio, info = eng.song(style, lyrics, cot, seed, abc_ids, sem_s, a.cfg_scale, a.steps,
                               on_latents=(lambda z, p=latents_path: np.save(p, np.array(z))) if a.keep_latents else None)
        wav = out / f"{name}.wav"
        eng.g.write_wav(wav, audio)
        takes.append({"file": wav.name, "seed": seed, **info})
        log(f"[done] {wav} {info['seconds']:.1f}s")

    record = {
        "request": {"style": style, "lyrics": lyrics, "cot": cot, "cot_requested": a.cot,
                    "abc_supplied": a.abc_file is not None, "tempo": a.tempo},
        "settings": {"cfg_scale": a.cfg_scale, "steps": a.steps or eng.pipe.ode_steps,
                     "max_tokens": tokens, "auto_length": a.auto_length,
                     "semantic_sampling": asdict(sem_s), "plan_sampling": asdict(abc_s)},
        "model": str(a.model), "plan_truncated": plan_truncated, "notes": notes,
        "takes": takes, "load_seconds": eng.load_seconds,
    }
    (out / "song.json").write_text(json.dumps(record, indent=2, default=str), encoding="utf-8")
    result({"out_dir": str(out), **record})


def cmd_plan(a):
    lyrics = a.lyrics if a.lyrics is not None else a.lyrics_file.read_text(encoding="utf-8")
    cot = "full" if a.cot == "auto" else a.cot
    if cot == "off":
        raise SystemExit("Planning Off has no score to produce.")
    eng = Engine(a.scripts, a.model)
    seed = seeds_for(a)[0]
    _, abc_text, truncated = eng.plan(a.style, lyrics, cot, seed, eng.sampling(eng.pipe.abc_sampling, a, "plan_"))
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(abc_text, encoding="utf-8")
    log(f"[done] {a.out}")
    result({"abc_file": str(a.out), "seed": seed, "truncated": truncated, "check": check_score(abc_text)})


def cmd_decode(a):
    import numpy as np
    import mlx.core as mx
    sys.path.insert(0, str(a.scripts))
    import generate as g
    from yue2_vae import load_vae
    vae = load_vae(a.model)
    log("[vae] decoding")
    audio = mx.clip(vae.decode_tiled(mx.array(np.load(a.latents))), -1, 1)
    g.write_wav(a.out, audio)
    log(f"[done] {a.out}")
    result({"file": str(a.out)})


def cmd_abc(a):
    text = a.score.read_text(encoding="utf-8")
    if a.action == "inspect":
        out = check_score(text)
        if out["ok"]:
            out["report"] = abc_tools.report(abc_tools.parse_abc(text))
        print(json.dumps(out, default=abc_tools.json_value))
    elif a.action == "set-tempo":
        a.output.write_text(set_tempo(text, a.bpm), encoding="utf-8")
        print(json.dumps({"file": str(a.output), "bpm": a.bpm}))
    elif a.action == "strip-chords":
        a.output.write_text(abc_tools.strip_chords(text, keep_voice=a.keep_voice), encoding="utf-8")
        print(json.dumps({"file": str(a.output)}))
    elif a.action == "fit-length":
        tokens, why = fit_tokens(text, a.fallback)
        print(json.dumps({"tokens": tokens, "note": why}))
    elif a.action == "compare":
        before = abc_tools.parse_abc(a.other.read_text(encoding="utf-8"))
        after = abc_tools.parse_abc(text)
        print(json.dumps(abc_tools.compare(before, after, allow_tempo_change=a.allow_tempo_change),
                         default=abc_tools.json_value))


def sampling_flags(p, prefix, label):
    p.add_argument(f"--{prefix}temperature", type=float, help=f"{label} randomness (model default: config)")
    p.add_argument(f"--{prefix}top-p", type=float, help=f"{label} nucleus cutoff")
    p.add_argument(f"--{prefix}top-k", type=int, help=f"{label} candidate limit")
    p.add_argument(f"--{prefix}repetition-penalty", type=float, help=f"{label} repetition penalty")
    p.add_argument(f"--{prefix}penalty-window", type=int, help=f"{label} tokens the penalty looks back over")


def request_flags(p):
    p.add_argument("--style", required=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--lyrics")
    g.add_argument("--lyrics-file", type=Path)
    p.add_argument("--cot", default="auto", choices=("auto", "full", "melody", "off"))
    p.add_argument("--seed", type=int)
    p.add_argument("--seeds", help="comma-separated seeds; overrides --seed/--takes")
    p.add_argument("--takes", type=int, default=1)
    sampling_flags(p, "plan-", "Score plan")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scripts", type=Path, help="folder holding the port's generate.py")
    ap.add_argument("--model", type=Path, help="model folder (bf16/8bit/4bit)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    gen = sub.add_parser("generate")
    request_flags(gen)
    sampling_flags(gen, "", "Music")
    gen.add_argument("--abc-file", type=Path, help="use this score instead of planning one")
    gen.add_argument("--tempo", type=int, help="rewrite the score's tempo (BPM); note lengths follow")
    gen.add_argument("--strip-chords", action="store_true", help="remove chord symbols from the score")
    gen.add_argument("--keep-voice", default="both", choices=("both", "Vocal", "Ins"))
    gen.add_argument("--cfg-scale", type=float, help="text guidance; model default 1.0 (1.01 when planning is off)")
    gen.add_argument("--steps", type=int, help="refinement steps; model default 32")
    gen.add_argument("--max-tokens", type=int, help=f"song length cap, 25 per second, at most {HARD_TOKEN_CAP}")
    gen.add_argument("--auto-length", action="store_true", help="size the length cap to the score")
    gen.add_argument("--keep-latents", action="store_true", help="keep latents for re-rendering")
    gen.add_argument("--out-dir", type=Path, required=True)

    pl = sub.add_parser("plan")
    request_flags(pl)
    pl.add_argument("--out", type=Path, required=True)

    dec = sub.add_parser("decode")
    dec.add_argument("--latents", type=Path, required=True)
    dec.add_argument("--out", type=Path, required=True)

    ab = sub.add_parser("abc")
    ab.add_argument("action", choices=("inspect", "set-tempo", "strip-chords", "fit-length", "compare"))
    ab.add_argument("score", type=Path)
    ab.add_argument("--output", type=Path)
    ab.add_argument("--bpm", type=int)
    ab.add_argument("--keep-voice", default="both", choices=("both", "Vocal", "Ins"))
    ab.add_argument("--fallback", type=int, default=4500)
    ab.add_argument("--other", type=Path, help="compare: the original score")
    ab.add_argument("--allow-tempo-change", action="store_true")

    a = ap.parse_args()
    if a.cmd in ("generate", "plan", "decode") and (a.scripts is None or a.model is None):
        ap.error("--scripts and --model are required for model commands")
    for name in ("temperature", "top_p", "top_k", "repetition_penalty", "penalty_window"):
        for pre in ("", "plan_"):
            if not hasattr(a, pre + name):
                setattr(a, pre + name, None)
    {"generate": cmd_generate, "plan": cmd_plan, "decode": cmd_decode, "abc": cmd_abc}[a.cmd](a)


if __name__ == "__main__":
    main()
