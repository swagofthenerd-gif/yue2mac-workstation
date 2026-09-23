#!/usr/bin/env python3
"""Listening test for live playback: one composition, refined whole vs. in sections.

Generates the plan and semantic tokens once (fixed seed), then renders:
  A-normal.wav            the standard whole-song refinement
  B-15s-with-end.wav      15 s sections, 2 s crossfade, each section closed like a chunk
  C-15s-open.wav          15 s sections, 2 s crossfade, sections left open (no end marker)
  D-30s-open.wav          30 s sections, 4 s crossfade, left open
and reports how long each section took against how long it plays.
"""
import json
import sys
import time
from pathlib import Path

import mlx.core as mx
import numpy as np

scripts, model_dir, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.insert(0, str(scripts))
import generate as g  # noqa: E402

STYLE = "English, indie pop, warm female vocal, bright acoustic guitar, soft drums, 100 BPM"
LYRICS = """[Verse]
Morning light across the kitchen floor
Coffee cooling by the open door
[Chorus]
Stay a little longer, stay with me
Every little moment feels like free
[Verse]
Pages turning in the afternoon
Humming half a melody in tune
[Chorus]
Stay a little longer, stay with me
Every little moment feels like free"""
SEED, TOKENS, STEPS = 2024, 1750, 32   # ~70 s of music

out.mkdir(parents=True, exist_ok=True)
pipe = g.Yue2Pipeline(model_dir, log=lambda m: None)
tok = pipe.tokenizer
t = time.perf_counter()
abc_ids, _ = g.generate_tokens(pipe.model, g.token_prefix(tok, STYLE, LYRICS, "full"), pipe.abc_sampling, SEED, "abc")
prefix = g.token_prefix(tok, STYLE, LYRICS, "full", abc_ids)
sem = g.Sampling(**{**pipe.semantic_sampling.__dict__, "max_tokens": TOKENS})
ids, _ = g.generate_tokens(pipe.model, prefix, sem, SEED, "semantic")
codec = [x - g.CODEC_OFFSET for x in ids]
compose_s = time.perf_counter() - t
frames = len(codec)
print(f"composed {frames} frames ({frames / 25:.1f}s) in {compose_s:.1f}s", flush=True)
noise = mx.random.normal((frames, 64), key=mx.random.key(SEED))


def refine(a, b, close):
    """Flow-matching for frames [a:b] as one chunk, same maths as g.synthesize."""
    ar_tokens = prefix + [c + g.CODEC_OFFSET for c in codec[a:b]] + ([g.MUSIC_END] if close else [])
    cache = pipe.model.nar_prefill(ar_tokens)
    state = noise[a:b].astype(mx.bfloat16)
    dt = 1.0 / STEPS
    for step in range(STEPS):
        tt = 1.0 - step * dt
        v1 = pipe.model.nar_velocity(state, g._logit(tt), cache, len(ar_tokens))
        mid = state - v1 * (dt / 2)
        state = state - pipe.model.nar_velocity(mid, g._logit(tt - dt / 2), cache, len(ar_tokens)) * dt
        mx.eval(state)
    return np.array(state.astype(mx.float32))


def sectioned(win_s, fade_s, close_all):
    win, fade = int(win_s * 25), int(fade_s * 25)
    lat = np.zeros((frames, 64), np.float32)
    timings, start = [], 0
    while start < frames:
        a = max(0, start - fade)
        b = min(frames, start + win)
        last = b >= frames
        t0 = time.perf_counter()
        z = refine(a, b, close=close_all or last)
        timings.append({"plays_s": (b - start) / 25, "took_s": round(time.perf_counter() - t0, 2)})
        if a < start:  # equal-power crossfade across the overlap
            n = start - a
            w = np.sin(np.linspace(0, np.pi / 2, n))[:, None] ** 2
            lat[a:start] = lat[a:start] * (1 - w) + z[:n] * w
            lat[start:b] = z[n:]
        else:
            lat[a:b] = z
        start = b
    return lat, timings


def save(name, lat):
    audio = pipe.decode(mx.array(lat))
    g.write_wav(out / name, audio)


report = {"compose_seconds": round(compose_s, 1), "song_seconds": frames / 25}
t = time.perf_counter()
full = np.array(g.synthesize(pipe.model, prefix, codec, SEED, STEPS))
report["A_normal_refine_seconds"] = round(time.perf_counter() - t, 1)
save("A-normal.wav", full)
for name, win, fade, close in (("B-15s-with-end.wav", 15, 2, True), ("C-15s-open.wav", 15, 2, False),
                               ("D-30s-open.wav", 30, 4, False)):
    lat, timings = sectioned(win, fade, close)
    save(name, lat)
    report[name] = {"sections": timings,
                    "max_section_rms_vs_normal": round(float(np.sqrt(((lat - full) ** 2).mean())), 4)}
    print(name, timings, flush=True)
(out / "report.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
