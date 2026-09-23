# Project notes — YuE2Mac Workstation

Started 2026-09-23 as a fork of [arinltte/YuE2Mac](https://github.com/arinltte/YuE2Mac) (MIT). Goal:
expose everything YuE2 can do, locally, in one app — "every little and big thing".

## How it fits together

```
SwiftUI app ──runs──▶ engine/yue2mac_engine.py  (MLX venv)  ──imports──▶ downloaded generate.py / yue2_model.py
            ──runs──▶ engine/transcribe.py      (SheetSage venv: SheetSage2 + MERT-v2)
            ──runs──▶ engine/audio_tools.py     (SheetSage venv: Demucs stems, Whisper lyrics check)
            ──runs──▶ engine/score_editor.py    (Claude Code CLI, verified by abc_tools)
```

The downloaded MLX port (`ahmadw/YuE2-3B-MLX`) is never modified; `yue2mac_engine.py` wraps its
building blocks so every stage and sampling control is reachable. Every helper prints progress lines
(`[plan]`, `[semantic]`, `[nar]`, `[transcribe]`…) and a final `[result] {json}` line.

## Decisions and why

- **CFG default 1.0** (the original app used 5.0). The YuE2 authors use 1.0 with `full`/`melody`
  planning; above 1 runs a second pass (~1.45× slower on the composing stage).
- **Length fitted to the score.** The old 4,500-token cap cut songs off: planned scores were 4–4.5 min.
  The engine sizes the cap to the score (×1.15 + 250 tokens), never above the model's 9,000 (6 min).
- **Instrumental fix.** Tagging the style "instrumental, no vocals" didn't stop singing, because the plan
  still wrote a Vocal melody. Now the score's Vocal notes become equal-length rests (chords and the Ins
  melody stay) before any audio is made.
- **Takes share one plan** — they're new performances of the same song, not new songs.
- **Custom scores go in as files** (`--abc-file`), so no escaping issues; planning mode is chosen from
  the score (chords → `full`, melody-only → `melody`).
- **"full-with-chords" doesn't exist** in YuE2: `full` already means melody + chords. "Harmonic
  blueprint" = `full` with your own chord-annotated score.
- **Cover Mode in its own Python env**: SheetSage2 pins older torch/numpy than MLX. transformers 4.45
  misses nested remote-code imports, so `transcribe.py` pre-copies the model code into its module cache.
- **Demucs + Whisper share the SheetSage env**, installed with a constraints file so the pins survive.
  Whisper invents "Thank you" over instrumental passages; those phrases are filtered.
- **No Xcode build**: the Mac this started on has no admin rights, no Apple ID sign-in, and Xcode 27
  needs macOS 26.6. Swapping `@Observable` for `ObservableObject` made it compile with the Command Line Tools.
- **Layout lesson**: `CardContainer` centres its content in an overlay, so tall content spills out of the
  top unseen (the Cover tab's upload area vanished). Use `TopCard` / `ScrollView` for tall content.

## Measurements (M2 Ultra, 64 GB, bf16)

| What | Result |
|---|---|
| Composing speed | ~105 tokens/s with CFG 1.0 (~4× real time); ~64–76 tok/s with CFG 5 |
| 60 s song, old defaults (CFG 5, 32 steps) | 76 s total: 20 s plan, 23 s compose, 32 s refine |
| 1:49 song, new defaults, auto length | 1:47 total, not truncated |
| SheetSage2 transcription | 77 s song in 8.5 s (Apple GPU) |
| Demucs stems | 1:49 song in 12 s |
| Refining in 15 s sections | ~8 s per section → live playback would stay ahead |

## Live playback (Suno-style) — built

`generate --live` refines and decodes ~15 s sections inside the composing loop's token callback
(`LiveStreamer` in `yue2mac_engine.py`), crossfading 2 s overlaps and announcing each finished
`live/section-NN.wav`; the app queues them gaplessly on an `AVAudioPlayerNode` (`LivePlayer.swift`).
By default the whole song is then rendered again in one piece (seamless) and saved; "Keep the streamed
version" skips that. Measured (self-test `YUE2MAC_SELFTEST=live`): 1:30 song, first sound at 26 s,
a new section every ~12.5 s, playback never waited, finished at 2:23 including the final render.

### Earlier: the listening test

`engine/stream_test.py` renders one composition four ways (whole; 15 s sections closed or open; 30 s
sections) into `Output/_tests/live-playback-test`. Objective check: section joins show no bigger tone or
loudness jumps than random moments in the same song. The listening verdict decides the default for "Keep the streamed version":
- joins clean and quality equal → stream sections and keep the streamed result;
- joins clean but whole render better → stream a preview, swap in the whole render when done;
- joins audible → longer overlaps / smarter crossfades first.


## Other ideas not built yet

- Re-decode a take with `YuE2-Vae-legacy` (needs an MLX port of that decoder).
- A compare-takes view (A/B playback).
- Lyric/phoneme alignment sidecars (official docs describe them; not a model input).
