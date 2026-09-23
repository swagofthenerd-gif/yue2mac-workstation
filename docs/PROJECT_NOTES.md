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

- **Covers: the Instrumental switch was deleting the melody.** Silencing the Vocal voice is right for a
  planned instrumental, but in a cover the transcribed tune *is* the Vocal voice. With a supplied score,
  Instrumental now moves the melody bar-by-bar into the Ins voice (`melody_to_instrument`, `Z4`-style
  multi-bar rests are expanded first). Measured on the user's reference: melody present in 8% of the old
  cover vs 62% of the fixed one (melody + chords).
- **Covers keep the original chords by default** (62% vs 38% melody presence), transcribed from the full
  mix (chords need the band, so vocal isolation is only used for melody-only covers). The score's BPM is
  added to the style prompt. A new reference recording sets any unrelated score aside (restorable), so a
  stale score can't silently replace the recording's melody.
- **Melody match** (`engine/melody_match.py`): after a cover, each take is transcribed and compared with
  the reference by pitch class on a 1/8 s grid with ±4 s offset search. Chance ≈ 0.17; two
  transcriptions of the same original agree ≈ 0.41, so the transcriber is the measurement ceiling.
- **YuE2 has no audio input** (official docs): covers carry melody, chords, tempo and structure, not the
  singer's voice or the production.

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

### Live sound quality — wired in

`LiveStreamer` now pins the last 8 s of already-played latents while refining each new section
(flow-matching inpainting), uses 24 steps, and sizes each section from the measured composing, refining
and per-section overhead so playback stays ahead (first section 16 s, then 15–30 s). A 6 s minimum caused
9 s of pauses (≈1 s fixed cost per section), so the minimum is 15 s. Measured: 1:30 song, first sound 24 s
after Generate, 5 sections, no pauses.

The app has one `Player` (AVAudioEngine + time-pitch) for live streams, takes, History and the reference
preview: waveform seek/scrub, ±10 s, restart, prev/next take, loop, 0.5–2× speed, volume/mute, and a
Playback menu (⌥Space, ⌥←/→, ⌥⇧←, ⌥L, ⌥M). Verified with `YUE2MAC_SELFTEST=player` (muted).

### Making the live sound closer to the final render (measurements)

`engine/live_quality_test.py`: closeness to the whole render (latent RMS; another whole render with
different noise = 1.12, i.e. equally valid) and refine cost per second of music (budget ≈ 0.75):
blend 0.66 / 0.65 · inpaint-4 0.56 / 0.71 · inpaint-8 0.48 / 0.76 · grow 8→16→30 s with 8 s pinned
context 0.53 / 0.64 · **grow 8→20→40 s, 12 s pinned context, 24 steps 0.51 / 0.50** ← best real-time option.
The live joins themselves are sample-smooth (no clicks); roughness comes from refining sections blind.

### Earlier: the listening test

`engine/stream_test.py` renders one composition four ways (whole; 15 s sections closed or open; 30 s
sections) into `Output/_tests/live-playback-test`. Objective check: section joins show no bigger tone or
loudness jumps than random moments in the same song. The listening verdict decides the default for "Keep the streamed version":
- joins clean and quality equal → stream sections and keep the streamed result;
- joins clean but whole render better → stream a preview, swap in the whole render when done;
- joins audible → longer overlaps / smarter crossfades first.


## LeVo 2 (Tencent SongGeneration 2) — feasibility test, 2026-09-23

- Runs on Apple Silicon via the community C++/GGML port `ckadirt/LeVo2.cpp` (pinned in
  `scripts/setup_levo2.sh`) **with our patch** `patches/levo2cpp-metal-causal-mask.patch`: that ggml
  build has no `DIAG_MASK_INF` on Metal (GPU aborts), so the causal mask is built from
  arange/sub/step and passed to `soft_max_ext`. First tokens match CPU exactly; later greedy tokens
  diverge from GPU/CPU rounding (normal). The port's 29 tests pass.
- CPU only: 10 s of music took 281 s (unusable). GPU (large, Q8_0): 30 s song = ~23 s load +
  ~75 s composing (~14 steps/s; real time needs ~33) + ~52 s render → ~5× slower than real time,
  so a 3-min song ≈ 10 min. Too slow for live playback.
- Lyrics: 24 of 27 words sung correctly on the test (YuE2's comparable test: 4 of 11).
- **No reference-audio prompt in this port** (prompt audio is always the null/empty prompt), so it
  doesn't help covers get closer to a recording.
- License: research, academic, education only — no commercial use.
- Lyrics format: `[verse] line. line ; [chorus] … ; [outro-short]`; tags verse, chorus, bridge,
  intro/inst/outro-short|medium|long, silence. Style: free text, e.g. "female, pop, the bpm is 100".

## Stem Remix (UVR5 + Stable Audio 3) — built 2026-09-23

Workflow from a second agent, adjusted: song (any take, History or file) → **UVR5 pass 1**
BS-RoFormer-Viperx-1297 (vocals out; best instrumental SDR) → **pass 2** Demucs v4 ft on the
instrumental (drums/bass/other, or 6-stem with guitar/piano; SCNet isn't in audio-separator) →
**Stable Audio 3** restyle of ticked stems (strength 0.2–1.0, default 0.6; bar-aligned equal chunks
for >110 s on Small), region regenerate, new layer → **mixer** (synced AVAudioPlayerNodes, gain/
mute/solo, version per stem) → export mix (ffmpeg amix normalize=0) or DAW stems (48 kHz, same length).

- audio-separator peak-normalises by default → stems didn't sum to the song (12 dB). `stems.py`
  runs un-normalised and least-squares re-fits gains: 81 dB / 28 dB reconstruction, bleed −73 dB.
- Stable Audio 3 code auto-selects MPS and falls back from flash-attn, so Medium may run on Mac —
  **untested: weights are gated** (needs the user's HF login + accepting SA3 and Gemma terms).
- Artist names are unlikely to steer SA3 (trained on licensed data); the UI says to describe the sound.

## Other ideas not built yet

- Re-decode a take with `YuE2-Vae-legacy` (needs an MLX port of that decoder).
- A compare-takes view (A/B playback).
- Lyric/phoneme alignment sidecars (official docs describe them; not a model input).
