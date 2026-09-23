#!/usr/bin/env python3
"""How closely does a song's melody follow a reference? Both given as native ABC scores.

    python melody_match.py reference.abc candidate.abc     -> {"match": 0.63, "offset_s": 0.4, ...}

Each score is flattened to a lead line in real time: the Vocal note where one sounds,
otherwise the Ins note. The two lead lines are sampled every 1/8 s and compared by pitch
class (octave doesn't matter) over the time both have a note, after trying time offsets
up to ±4 s (a cover can start a little early or late). Chance level for unrelated tonal
music is roughly 0.1–0.2; the same melody transcribed twice lands well above 0.5.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import abc_tools  # noqa: E402

STEP = 0.125  # seconds


def lead_line(text: str) -> list:
    score = abc_tools.parse_abc(text)
    spq = 60.0 / score.bpm  # seconds per quarter
    end = float(max(v.time for v in score.voices.values())) * spq
    grid = [None] * (int(end / STEP) + 1)
    for name in ("Ins", "Vocal"):  # Vocal written last, so it wins where both sound
        for onset, pitch, dur in score.voices[name].notes:
            a, b = float(onset) * spq, float(onset + dur) * spq
            for i in range(int(a / STEP), min(len(grid), int(b / STEP))):
                grid[i] = pitch % 12
    return grid


def compare(ref: list, cand: list, max_shift_s=4.0) -> dict:
    best = {"match": 0.0, "offset_s": 0.0, "overlap_s": 0.0}
    span = int(max_shift_s / STEP)
    for shift in range(-span, span + 1):
        hit = both = 0
        for i, p in enumerate(ref):
            j = i + shift
            if p is None or not 0 <= j < len(cand) or cand[j] is None:
                continue
            both += 1
            hit += p == cand[j]
        if both and hit / both > best["match"]:
            best = {"match": round(hit / both, 3), "offset_s": shift * STEP, "overlap_s": both * STEP}
    ref_notes = sum(p is not None for p in ref) * STEP
    best["coverage"] = round(best["overlap_s"] / ref_notes, 3) if ref_notes else 0.0
    return best


def main():
    ref, cand = (Path(p).read_text(encoding="utf-8") for p in sys.argv[1:3])
    print(json.dumps(compare(lead_line(ref), lead_line(cand))))


if __name__ == "__main__":
    main()
