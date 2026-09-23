#!/usr/bin/env python3
"""Audio helpers for YuE2Mac, run in the Cover Mode (SheetSage2) environment.

    stems   <audio> --out DIR        vocals / drums / bass / other with Demucs (htdemucs)
    vocals  <audio> --out FILE       just the isolated vocal, e.g. before transcribing a cover
    lyrics  <audio> --lyrics-file F  what the song actually sings vs. the intended lyrics
    fetch                            download the Demucs and Whisper weights (setup only)

Weights live under the models folder given by --models, so nothing is fetched at
run time after setup. Audio is decoded with ffmpeg. Progress goes to stderr as
`[stems] …` / `[lyrics] …`, the summary as a final `[result] {json}` line.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def result(payload):
    log("[result] " + json.dumps(payload))


def decode(path: Path, ffmpeg: str, rate: int, channels: int):
    import numpy as np
    raw = subprocess.run([ffmpeg, "-v", "error", "-nostdin", "-i", str(path), "-ac", str(channels),
                          "-ar", str(rate), "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, channels).T.copy()


def write_wav(path: Path, audio, rate: int):
    import soundfile as sf
    sf.write(str(path), audio.T, rate, subtype="PCM_24")


def separator(models: Path):
    # demucs 4.1 fetches weights from the Hugging Face hub; keep them in the app's folder.
    os.environ["HF_HOME"] = str(models / "hf")
    import torch
    from demucs.api import Separator
    device = "mps" if torch.backends.mps.is_available() else "cpu"

    def progress(info):
        done = info.get("segment_offset", 0) + info.get("model_idx_in_bag", 0)
        total = info.get("audio_length") or 0
        if total:
            log(f"[stems] {min(100, int(100 * info.get('segment_offset', 0) / total))}%")
    return Separator("htdemucs", device=device, callback=progress), device


def separate(audio_path: Path, a):
    import torch
    sep, device = separator(a.models)
    log(f"[stems] separating on {device}")
    wav = decode(audio_path, a.ffmpeg, sep.samplerate, 2)
    _, stems = sep.separate_tensor(torch.from_numpy(wav), sep.samplerate)
    return {k: v.cpu().numpy() for k, v in stems.items()}, sep.samplerate


def cmd_stems(a):
    t0 = time.perf_counter()
    stems, rate = separate(a.audio, a)
    a.out.mkdir(parents=True, exist_ok=True)
    files = []
    for name, audio in stems.items():
        p = a.out / f"{name}.wav"
        write_wav(p, audio, rate)
        files.append(p.name)
    log(f"[done] {a.out}")
    result({"dir": str(a.out), "files": files, "seconds": time.perf_counter() - t0})


def cmd_vocals(a):
    stems, rate = separate(a.audio, a)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    write_wav(a.out, stems["vocals"], rate)
    log(f"[done] {a.out}")
    result({"file": str(a.out)})


# ── Lyrics check ────────────────────────────────────────────────────────────

WORD = re.compile(r"[\w']+", re.UNICODE)


def words(text: str) -> list[str]:
    return [w.lower().strip("'") for w in WORD.findall(text) if w.strip("'")]


def sung_lines(lyrics: str) -> list[str]:
    """Lyric lines that should be sung: drop [section] tags and blank lines."""
    return [l.strip() for l in lyrics.splitlines()
            if l.strip() and not re.fullmatch(r"\[[^\]]*\]", l.strip())]


def compare_lyrics(intended: str, heard: str) -> dict:
    want, got = words(intended), words(heard)
    sm = difflib.SequenceMatcher(a=want, b=got, autojunk=False)
    matched = [False] * len(want)
    edits = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for i in range(i1, i2):
                matched[i] = True
        else:
            edits += max(i2 - i1, j2 - j1)
    wer = edits / max(len(want), 1)
    # Per line: share of its words found in order.
    lines, k = [], 0
    for line in sung_lines(intended):
        n = len(words(line))
        hit = sum(matched[k:k + n])
        lines.append({"line": line, "found": hit, "words": n})
        k += n
    return {"word_error_rate": round(wer, 3), "words_intended": len(want), "words_heard": len(got),
            "words_found": sum(matched), "lines": lines}


PHANTOM_PHRASES = {"thank you", "thanks for watching", "thank you for watching", "thank you so much",
                   "you", "bye", "music", "subtitles by the amara org community", "please subscribe"}


def whisper_dir(models: Path) -> Path:
    return models / "whisper-large-v3-turbo"


def cmd_lyrics(a):
    import mlx_whisper
    lyrics = a.lyrics_file.read_text(encoding="utf-8")
    source = a.audio
    if a.isolate:
        stems, rate = separate(a.audio, a)
        source = a.work / "vocals-for-lyrics.wav"
        source.parent.mkdir(parents=True, exist_ok=True)
        write_wav(source, stems["vocals"], rate)
    model = whisper_dir(a.models)
    if not (model / "config.json").exists():
        raise SystemExit("The lyrics model isn't installed. Open Settings → Install Cover Mode.")
    log("[lyrics] listening for words")
    # Whisper reads audio through ffmpeg on PATH.
    os.environ["PATH"] = str(Path(a.ffmpeg).parent) + os.pathsep + os.environ.get("PATH", "")
    lang = None if a.language == "auto" else a.language
    out = mlx_whisper.transcribe(str(source), path_or_hf_repo=str(model), language=lang,
                                 condition_on_previous_text=False, initial_prompt=None)
    # Whisper invents stock phrases over music with no singing; drop those segments.
    segments = [seg for seg in out.get("segments", [])
                if " ".join(words(seg["text"])) not in PHANTOM_PHRASES]
    heard = " ".join(seg["text"].strip() for seg in segments).strip()
    report = compare_lyrics(lyrics, heard)
    report.update({"heard": heard, "language": out.get("language"), "isolated": a.isolate,
                   "segments": [{"start": round(s["start"], 2), "end": round(s["end"], 2), "text": s["text"].strip()}
                                for s in segments]})
    if a.out:
        a.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    log("[done] lyrics check")
    result(report)


def cmd_fetch(a):
    os.environ.pop("HF_HUB_OFFLINE", None)
    from huggingface_hub import snapshot_download
    log("[fetch] Whisper large-v3-turbo")
    snapshot_download(repo_id=WHISPER_REPO, local_dir=str(whisper_dir(a.models)))
    log("[fetch] Demucs htdemucs")
    separator(a.models)[0]  # constructing it downloads the weights into HF_HOME
    result({"ok": True})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", type=Path, required=True)
    ap.add_argument("--ffmpeg", default="ffmpeg")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stems"); s.add_argument("audio", type=Path); s.add_argument("--out", type=Path, required=True)
    v = sub.add_parser("vocals"); v.add_argument("audio", type=Path); v.add_argument("--out", type=Path, required=True)
    l = sub.add_parser("lyrics")
    l.add_argument("audio", type=Path)
    l.add_argument("--lyrics-file", type=Path, required=True)
    l.add_argument("--isolate", action="store_true", help="separate the vocal first (more accurate)")
    l.add_argument("--language", default="auto", help="e.g. en, zh, ja; auto-detect by default")
    l.add_argument("--work", type=Path, default=Path("/tmp"))
    l.add_argument("--out", type=Path)
    sub.add_parser("fetch")
    a = ap.parse_args()
    {"stems": cmd_stems, "vocals": cmd_vocals, "lyrics": cmd_lyrics, "fetch": cmd_fetch}[a.cmd](a)


if __name__ == "__main__":
    main()
