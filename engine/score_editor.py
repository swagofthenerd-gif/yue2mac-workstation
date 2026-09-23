#!/usr/bin/env python3
"""Edit a YuE2 score in plain words with Claude, then verify it before use.

    python score_editor.py --score in.abc --instruction "jazzier chords" \
        --contract keep-melody --out edited.abc [--claude PATH] [--model NAME]

Runs the Claude Code CLI in print mode (your Claude subscription), asks for the
complete edited score in YuE2's native ABC dialect, and checks the answer with the
official YuE2 score tools: it must parse, and under `keep-melody` every sounding
note, onset, duration and meter must be unchanged (tempo only if the instruction
changes it). A failed check is sent back to Claude for up to two repairs.

Contracts:
    keep-melody   only chords (and tempo, if asked) may change      — reharmonise
    keep-rhythm   pitches may change, rhythm and bars may not        — new tune, same groove
    free          anything, as long as the format stays native       — rewrite sections, solos…

Progress: `[edit] …` lines on stderr; summary: a final `[result] {json}` line.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import abc_tools  # noqa: E402

RULES = """YuE2 reads a limited two-voice ABC dialect. Your score MUST follow it exactly:
- Keep the header fields (X:, T:, M:, L:, Q:, both V: declarations, K:) and the same L: unit.
  Change Q: (tempo) only if the request is about tempo.
- Music comes in groups of 1-4 bars: a `V: Vocal` line and its bars, then a `V: Ins` line and the
  same number of bars. `% intro`, `% verse`, `% chorus`, `% bridge`, `% interlude`, `% outro`
  comments start sections. Every music line ends with a plain barline `|`.
- Both voices are single-note melodies (no stacked notes). Vocal = sung melody, Ins = instrumental melody.
- Chords are quoted symbols placed in the Vocal voice at the moment they start, even over rests:
  e.g. "Am7"z16. Allowed qualities after the root: (none), m, dim, aug, 7, maj7, m7, dim7, m7b5,
  sus4, sus2, 6, m6, 7sus4, m(maj7). Slash bass allowed (e.g. "F#m7/C#"). Nothing else: no 9ths,
  13ths, alt, or C:maj.
- Note lengths are multiples of L: using only 1,2,3,4,6,8,12,16,24,32,48. Split other lengths with a
  tie, e.g. C8-C2. Every bar must add up to exactly one bar of the meter. Z/Z2 are whole-bar rests.
- A chord change inside a held note splits it with a tie: "C"E16-"Am7"E16. Ties join equal pitches;
  rests can't be tied; the score can't end on an open tie.
- Accidentals (^ _ =) last to the end of the bar and apply to that letter in every octave.
- Not allowed: tuplets, grace notes, chords-in-brackets [CEG], repeats, endings, slurs, decorations,
  broken rhythms (> <), lyric w: lines, extra voices or directives.
- A meter or key change starts a new group and appears as matching M: or K: lines in BOTH voice blocks."""

CONTRACTS = {
    "keep-melody": "Every sounding note in BOTH voices (pitch, start, length), every bar and meter must stay "
                   "exactly the same. Change only chord symbols (add ties to split held notes where a chord "
                   "changes mid-note), and the Q: tempo only if asked.",
    "keep-rhythm": "Keep every bar, meter and every note's start and length (and all rests) exactly the same. "
                   "You may change pitches and chord symbols.",
    "free": "You may change notes, rhythm, chords, sections and tempo as the request needs, but keep the "
            "native format and keep the song's sections recognisable unless asked otherwise.",
}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def ask_claude(claude: str, prompt: str, model: str | None) -> str:
    cmd = [claude, "-p", "--output-format", "text"]
    if model:
        cmd += ["--model", model]
    r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f"Claude CLI failed: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


def extract(reply: str) -> tuple[str | None, str]:
    """(score, explanation) from Claude's reply."""
    m = re.search(r"```(?:abc)?\s*\n(.*?)```", reply, re.S)
    score = m.group(1) if m else None
    if score is None and "X:" in reply:
        score = reply[reply.index("X:"):]
    explanation = re.sub(r"```.*?```", "", reply, flags=re.S).strip()
    if score is not None:
        score = score.strip() + "\n"
    return score, explanation


def verify(before_text: str, after_text: str, contract: str, allow_tempo: bool) -> list[str]:
    problems = []
    try:
        after = abc_tools.parse_abc(after_text)
    except Exception as exc:
        return [f"The score doesn't parse: {exc}"]
    before = abc_tools.parse_abc(before_text)
    if contract == "keep-melody":
        c = abc_tools.compare(before, after, allow_tempo_change=allow_tempo)
        if not c["match"]:
            problems += [f"Melody changed: {d}" for d in c["differences"][:12]]
    elif contract == "keep-rhythm":
        if before.bpm != after.bpm and not allow_tempo:
            problems.append("Tempo changed")
        for name in abc_tools.VOICES:
            b, a = before.voices[name], after.voices[name]
            if b.bars != a.bars:
                problems.append(f"{name}: bar grid or meters changed")
            # notes are [onset, pitch, duration]; the rhythm is the onsets and durations.
            if [(n[0], n[2]) for n in b.notes] != [(n[0], n[2]) for n in a.notes]:
                problems.append(f"{name}: note rhythm (starts or lengths) changed")
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--score", type=Path, required=True)
    ap.add_argument("--instruction", required=True)
    ap.add_argument("--contract", choices=tuple(CONTRACTS), default="keep-melody")
    ap.add_argument("--allow-tempo-change", action="store_true")
    ap.add_argument("--style", default="", help="the song's style prompt, for context")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--claude", default=str(Path.home() / ".local/bin/claude"))
    ap.add_argument("--model")
    ap.add_argument("--attempts", type=int, default=3)
    a = ap.parse_args()

    source = a.score.read_text(encoding="utf-8")
    try:
        abc_tools.parse_abc(source)
    except Exception as exc:
        raise SystemExit(f"The current score isn't valid native ABC, so edits can't be checked: {exc}")
    allow_tempo = a.allow_tempo_change or bool(re.search(r"\b(tempo|bpm|faster|slower)\b", a.instruction, re.I))

    prompt = (f"You are editing a song score for the YuE2 music model.\n\n{RULES}\n\n"
              f"What must stay fixed: {CONTRACTS[a.contract]}\n\n"
              + (f"The song's style prompt (context only): {a.style}\n\n" if a.style else "")
              + f"Request: {a.instruction}\n\nCurrent score:\n```abc\n{source}```\n\n"
              "Reply with the COMPLETE edited score in one ```abc code block, then at most 8 short "
              "bullet points saying what you changed and where (section / bar). No other text.")
    explanation, score, problems = "", None, []
    for attempt in range(1, a.attempts + 1):
        log(f"[edit] asking Claude (attempt {attempt} of {a.attempts})")
        reply = ask_claude(a.claude, prompt, a.model)
        score, explanation = extract(reply)
        if score is None:
            problems = ["No score in the reply"]
        else:
            problems = verify(source, score, a.contract, allow_tempo)
        if not problems:
            break
        log(f"[edit] check failed: {problems[0]}")
        prompt = (f"{RULES}\n\nWhat must stay fixed: {CONTRACTS[a.contract]}\n\nRequest: {a.instruction}\n\n"
                  f"Original score:\n```abc\n{source}```\n\nYour last attempt:\n```abc\n{score or ''}```\n\n"
                  "It failed these checks:\n- " + "\n- ".join(problems) +
                  "\n\nFix only what's needed. Reply with the COMPLETE corrected score in one ```abc block, "
                  "then at most 8 short bullets of what you changed.")
    ok = not problems
    if ok:
        a.out.write_text(score, encoding="utf-8")
        log(f"[done] {a.out}")
    compare = None
    if ok:
        try:
            compare = abc_tools.compare(abc_tools.parse_abc(source), abc_tools.parse_abc(score),
                                        allow_tempo_change=True)
        except Exception:
            pass
    log("[result] " + json.dumps({"ok": ok, "file": str(a.out) if ok else None, "explanation": explanation,
                                  "problems": problems, "attempts": attempt, "contract": a.contract,
                                  "melody_unchanged": bool(compare and compare["match"])}))
    sys.exit(0 if ok else 2)


if __name__ == "__main__":
    main()
