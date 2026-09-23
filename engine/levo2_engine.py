#!/usr/bin/env python3
"""LeVo 2 (Tencent SongGeneration 2) as a second song generator for YuE2Mac.

    python levo2_engine.py --levo-dir DIR --style "female, pop" --lyrics-file lyrics.txt \
        --seconds 150 --takes 2 --seed 7 --out-dir SONG_FOLDER [--instrumental]

Runs the Metal build from scripts/setup_levo2.sh: `levo-cli` (lyrics + style → three token
streams) then `levo-render` (tokens → 48 kHz stereo). Lyrics written the app's way
([Verse] on its own line, one sung line per line) are converted to LeVo's format
(`[verse] line. line ; [chorus] …`). Progress is re-emitted in the app's own line format
([note] / [take] / [semantic] / [nar] / [vae] / [done]) and a `song.json` compatible with
the app's history is written. Research/education use only (Tencent SongGeneration terms).
"""
from __future__ import annotations

import argparse
import json
import random
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

TAGS = {
    "intro": "intro-short", "verse": "verse", "pre-chorus": "verse", "prechorus": "verse",
    "chorus": "chorus", "hook": "chorus", "bridge": "bridge", "instrumental": "inst-medium",
    "inst": "inst-medium", "interlude": "inst-short", "solo": "inst-medium", "break": "inst-short",
    "outro": "outro-short", "silence": "silence",
}
EMPTY_TAGS = {"intro-short", "intro-medium", "intro-long", "inst-short", "inst-medium", "inst-long",
              "outro-short", "outro-medium", "outro-long", "silence"}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def to_levo_lyrics(text: str, instrumental: bool) -> str:
    """App lyrics → LeVo sections. Unknown tags become verses; untagged lines start a verse."""
    if instrumental:
        return "[intro-short] ; [inst-long] ; [inst-medium] ; [outro-short]"
    sections, tag, lines = [], None, []

    def flush():
        if tag is None and not lines:
            return
        t = tag or "verse"
        if t in EMPTY_TAGS:
            sections.append(f"[{t}]")
        elif lines:
            body = ". ".join(l.rstrip(" .,;") for l in lines)
            sections.append(f"[{t}] {body}")
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = re.fullmatch(r"\[([^\]]+)\]", line)
        if m:
            flush()
            name = m.group(1).strip().lower()
            name = re.sub(r"\s*\d+$", "", name)          # "Verse 2" -> "verse"
            tag, lines = TAGS.get(name, "verse"), []
        else:
            lines.append(line.replace(";", ","))
    flush()
    if not sections:
        raise SystemExit("LeVo 2 needs lyrics (or turn on Instrumental).")
    if not sections[0].startswith("[intro"):
        sections.insert(0, "[intro-short]")
    if not sections[-1].startswith("[outro"):
        sections.append("[outro-short]")
    return " ; ".join(sections)


def wav_seconds(path: Path):
    """Length of the rendered file (levo-render writes 32-bit float WAV, which `wave` can't read)."""
    try:
        data = path.read_bytes()
        i = data.find(b"fmt ")
        ch = int.from_bytes(data[i + 10:i + 12], "little")
        rate = int.from_bytes(data[i + 12:i + 16], "little")
        bits = int.from_bytes(data[i + 22:i + 24], "little")
        j = data.find(b"data")
        size = int.from_bytes(data[j + 4:j + 8], "little")
        return size / (ch * rate * bits / 8)
    except Exception:
        return None


CURRENT = None


def _stop(signum, _frame):
    """The app's Stop sends SIGINT/SIGTERM to this script; take the GPU job down with it."""
    if CURRENT and CURRENT.poll() is None:
        CURRENT.terminate()
        try:
            CURRENT.wait(timeout=5)
        except subprocess.TimeoutExpired:
            CURRENT.kill()
    sys.exit(130)


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)


def run(cmd, on_line):
    global CURRENT
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    CURRENT = p
    tail = []
    for line in p.stdout:
        line = line.rstrip()
        if line.startswith("ggml_"):
            continue
        tail = (tail + [line])[-20:]
        on_line(line)
    if p.wait() != 0:
        raise SystemExit("LeVo 2 failed: " + " | ".join(l for l in tail if l)[-600:])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--levo-dir", type=Path, required=True)
    ap.add_argument("--size", default="large", choices=("large", "medium"))
    ap.add_argument("--style", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--lyrics")
    g.add_argument("--lyrics-file", type=Path)
    ap.add_argument("--instrumental", action="store_true")
    ap.add_argument("--seconds", type=float, default=120)
    ap.add_argument("--takes", type=int, default=1)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--steps", type=int, help="render (flow) steps; the port's default when omitted")
    ap.add_argument("--cfg", type=float, help="render guidance; the port's default when omitted")
    ap.add_argument("--out-dir", type=Path, required=True)
    a = ap.parse_args()

    bin_dir, models = a.levo_dir / "bin", a.levo_dir / "models"
    lm = models / f"LeVo2-v2-{a.size}-Q8_0.gguf"
    flow, vae = models / "LeVo2-v2-flow-Q8_0.gguf", models / "LeVo2-v2-vae-F32.gguf"
    for f in (bin_dir / "levo-cli", bin_dir / "levo-render", lm, flow, vae):
        if not f.exists():
            raise SystemExit(f"LeVo 2 isn't installed ({f.name} missing). Run scripts/setup_levo2.sh.")
    seconds = max(10.0, min(270.0, a.seconds))       # LeVo 2 songs top out at 4:30
    lyrics = a.lyrics if a.lyrics is not None else a.lyrics_file.read_text(encoding="utf-8")
    levo_lyrics = to_levo_lyrics(lyrics, a.instrumental)
    a.out_dir.mkdir(parents=True, exist_ok=True)
    (a.out_dir / "levo-lyrics.txt").write_text(levo_lyrics, encoding="utf-8")
    steps_total = int(seconds * 100 / 3 + 0.5)       # the port runs ~33.3 steps per second of music
    log(f"[note] LeVo 2 ({a.size}, 8-bit) · {seconds:.0f}s · -> {steps_total} tokens")
    first = a.seed if a.seed is not None else random.randint(0, 999_999)
    takes = []
    t_start = time.perf_counter()
    for i in range(a.takes):
        seed = first + i
        name = f"take-{i + 1}" if a.takes > 1 else "song"
        log(f"[take] {i + 1}/{a.takes} seed {seed}")
        tokens = a.out_dir / f"{name}.tokens.npy"
        log("[semantic] prefix 0 tokens, cfg 1.0")

        def composing(line):
            m = re.search(r"generating (\d+)/(\d+) steps .*?([0-9.]+) step/s", line)
            if m:
                log(f"[semantic] {m.group(1)} tokens, {m.group(3)} tok/s")
        cmd = [str(bin_dir / "levo-cli"), "--model", str(lm), "--lyrics", str(a.out_dir / "levo-lyrics.txt"),
               "--prompt", a.style, "--duration", f"{seconds:.0f}", "--output", str(tokens),
               "--backend", "gpu", "--seed", str(seed), "--progress-interval", "2"]
        t0 = time.perf_counter()
        run(cmd, composing)
        compose_s = time.perf_counter() - t0

        log(f"[nar] {steps_total} frames ({seconds:.1f}s), rendering")
        def rendering(line):
            m = re.search(r"(\d+)/(\d+) windows", line)
            if m and int(m.group(2)) > 0:
                log(f"[nar] step {int(m.group(1))}/{int(m.group(2))}")
            if "assembling_audio" in line:
                log("[vae] decoding")
        wav = a.out_dir / f"{name}.wav"
        cmd = [str(bin_dir / "levo-render"), str(tokens), "--flow-model", str(flow), "--vae-model", str(vae),
               "--output", str(wav), "--backend", "gpu", "--seed", str(seed), "--progress-interval", "2"]
        if a.steps:
            cmd += ["--steps", str(a.steps)]
        if a.cfg:
            cmd += ["--cfg", str(a.cfg)]
        t0 = time.perf_counter()
        run(cmd, rendering)
        render_s = time.perf_counter() - t0
        seconds_out = wav_seconds(wav) or seconds
        takes.append({"file": wav.name, "seed": seed, "seconds": seconds_out, "semantic_truncated": False,
                      "guidance": 1.0, "timings": {"compose": compose_s, "render": render_s}})
        log(f"[done] {wav} {seconds_out:.1f}s")

    record = {
        "request": {"style": a.style, "lyrics": lyrics, "cot": "levo2", "cot_requested": "levo2",
                    "abc_supplied": False, "tempo": None, "instrumental": a.instrumental},
        "settings": {"cfg_scale": a.cfg, "steps": a.steps, "max_tokens": steps_total, "generator": f"levo2-{a.size}"},
        "model": str(lm), "notes": [f"LeVo 2 lyrics: {levo_lyrics}"], "takes": takes,
        "load_seconds": 0, "total_seconds": time.perf_counter() - t_start,
    }
    (a.out_dir / "song.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    log("[result] " + json.dumps({"out_dir": str(a.out_dir)}))


if __name__ == "__main__":
    main()
