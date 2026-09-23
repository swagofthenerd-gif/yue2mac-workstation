#!/usr/bin/env python3
"""How close can live (sectioned) refinement get to the whole-song render, in real time?

One composition, one noise field. The whole-song render is the reference. Each variant
refines the song section by section as it would during live playback and reports:
  - closeness: RMS distance to the reference latents on the frames it plays (lower = closer)
  - realtime: refine seconds per second of new music (must leave room for composing, ~0.25)
Variants:
  blend       current: 15 s sections, 2 s latent crossfade, no context
  inpaint-N   N s of already-played latents pinned as context (flow-matching inpainting)
  grow        sections 8 s -> 16 s -> 30 s, 6 s pinned context
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
LYRICS = "[Verse]\nMorning light across the kitchen floor\nCoffee cooling by the open door\n[Chorus]\nStay a little longer, stay with me\nEvery little moment feels like free\n[Verse]\nPages turning in the afternoon\n[Chorus]\nStay a little longer, stay with me"
SEED, TOKENS, STEPS = 2024, 2250, 32
out.mkdir(parents=True, exist_ok=True)
pipe = g.Yue2Pipeline(model_dir, log=lambda m: None)
tok = pipe.tokenizer
abc_ids, _ = g.generate_tokens(pipe.model, g.token_prefix(tok, STYLE, LYRICS, "full"), pipe.abc_sampling, SEED, "abc")
prefix = g.token_prefix(tok, STYLE, LYRICS, "full", abc_ids)
ids, _ = g.generate_tokens(pipe.model, prefix, g.Sampling(**{**pipe.semantic_sampling.__dict__, "max_tokens": TOKENS}), SEED, "semantic")
codec = [x - g.CODEC_OFFSET for x in ids]
F = len(codec)
noise = mx.random.normal((F, 64), key=mx.random.key(SEED))
print(f"{F} frames ({F / 25:.0f}s)", flush=True)

t = time.perf_counter()
ref = np.array(g.synthesize(pipe.model, prefix, codec, SEED, STEPS))
ref_rate = (time.perf_counter() - t) / (F / 25)
print(f"whole render: {ref_rate:.2f} s per s of music", flush=True)


def refine(a, b, close, known=None, steps=None):
    """Frames [a:b]; `known` pins the first len(known) frames to already-played latents."""
    ar = prefix + [c + g.CODEC_OFFSET for c in codec[a:b]] + ([g.MUSIC_END] if close else [])
    cache = pipe.model.nar_prefill(ar)
    nz = noise[a:b].astype(mx.bfloat16)
    state = nz
    k = 0 if known is None else len(known)
    x0 = None if known is None else mx.array(known).astype(mx.bfloat16)
    n_steps = steps or STEPS
    dt = 1.0 / n_steps

    def pin(s, tt):
        if not k:
            return s
        # rectified flow: x_t = t * noise + (1 - t) * x0 on the pinned frames
        return mx.concatenate([nz[:k] * tt + x0 * (1 - tt), s[k:]], axis=0)

    for step in range(n_steps):
        tt = 1.0 - step * dt
        state = pin(state, tt)
        v1 = pipe.model.nar_velocity(state, g._logit(tt), cache, len(ar))
        mid = pin(state - v1 * (dt / 2), tt - dt / 2)
        state = state - pipe.model.nar_velocity(mid, g._logit(tt - dt / 2), cache, len(ar)) * dt
        mx.eval(state)
    state = pin(state, 0.0)
    return np.array(state.astype(mx.float32))


def run(name, sizes, ctx_s, blend_s, steps=None):
    lat = np.zeros((F, 64), np.float32)
    start, i, spent, secs = 0, 0, 0.0, []
    while start < F:
        win = int(sizes[min(i, len(sizes) - 1)] * 25)
        b = min(F, start + win)
        last = b >= F
        t0 = time.perf_counter()
        if ctx_s and start > 0:
            a = max(0, start - int(ctx_s * 25))
            z = refine(a, b, last, known=lat[a:start], steps=steps)
            lat[start:b] = z[start - a:]
        elif blend_s and start > 0:
            a = max(0, start - int(blend_s * 25))
            z = refine(a, b, last)
            n = start - a
            w = (np.sin(np.linspace(0, np.pi / 2, n)) ** 2)[:, None]
            lat[a:start] = lat[a:start] * (1 - w) + z[:n] * w
            lat[start:b] = z[n:]
        else:
            lat[start:b] = refine(start, b, last, steps=steps)
        dt = time.perf_counter() - t0
        spent += dt
        secs.append(round(dt / ((b - start) / 25), 2))
        start, i = b, i + 1
    dist = float(np.sqrt(((lat - ref) ** 2).mean()))
    audio = pipe.decode(mx.array(lat))
    g.write_wav(out / f"{name}.wav", audio)
    return {"closeness_rms": round(dist, 3), "refine_s_per_music_s": round(spent / (F / 25), 2),
            "worst_section_rate": max(secs), "sections": len(secs)}


g.write_wav(out / "reference-whole.wav", pipe.decode(mx.array(ref)))
# Natural variation: another whole render with different noise is an equally valid result.
alt = np.array(g.synthesize(pipe.model, prefix, codec, SEED + 1, STEPS))
report = {"reference_rate": round(ref_rate, 2), "latent_std": round(float(ref.std()), 3),
          "another_whole_render_rms": round(float(np.sqrt(((alt - ref) ** 2).mean())), 3)}
print(report, flush=True)
for name, sizes, ctx, blend, steps in (("blend", [15], 0, 2, None), ("inpaint-4", [15], 4, 0, None),
                                       ("inpaint-8", [15], 8, 0, None), ("grow-ctx8", [8, 16, 30], 8, 0, None),
                                       ("grow-ctx12", [8, 20, 40], 12, 0, None),
                                       ("grow-ctx12-24steps", [8, 20, 40], 12, 0, 24)):
    report[name] = run(name, sizes, ctx, blend, steps)
    print(name, report[name], flush=True)
(out / "report.json").write_text(json.dumps(report, indent=2))
