# Limitations and bottlenecks — as of 2026-09-24

What stands between this workstation and Suno-level results, with the evidence we measured. Written
to decide what to try next; each item ends with what could unblock it.

## 1. The ceiling is the models, not the app

- **No open, local model matches Suno/Udio.** Their covers and remixes condition a large proprietary
  model directly on your audio; nothing released openly does that at their quality.
- **YuE2-3B** (our main generator) is a 3B research model: good structure and lyrics-following, but
  mixed audio fidelity, and it can't take audio as input (official docs: no `reference_audio`).
- **LeVo 2** sings lyrics very accurately (24/27 words vs YuE2's 4/11 in one test) but on this Mac it
  runs ~5× slower than real time, and the Mac-capable port has **no reference-audio prompt**.
- **Stable Audio 3** is instrumental/sound only (no singing), and its audio-to-audio is a
  noise-and-denoise edit, not a true "restyle".
- *Unblock:* a stronger model (new open release, or a paid API with terms that allow it), or
  fine-tuning (see §6).

## 2. Songs from a prompt

- **Audio quality** is YuE2's; 32 refinement steps is the model's reference, more doesn't help.
- **Lyrics drift:** YuE2 sometimes changes or drops lines (lyrics check: "light" → "life", chorus
  missing). LeVo 2 is much better at this but slow.
- **Length:** YuE2 caps at 9,000 tokens (6:00); LeVo 2 at 4:30.
- **Live playback** is a preview: sectioned refinement never equals the whole-song render (closeness
  0.48–0.53 vs 0.66 before pinning context; another valid render = 1.12).
- **Randomness:** takes vary a lot; best results need several takes and picking.
- *Unblock:* LeVo 2 on faster hardware (NVIDIA / cloud GPU) for lyric-critical songs; more takes +
  automatic picking (lyrics check + melody match already exist).

## 3. Covers of existing songs (YuE2 via transcription)

- **Only the notes survive.** The pipeline is audio → SheetSage2 score (melody, chords, tempo) →
  YuE2 performs it anew. The singer's voice, the production and the exact timing are not carried.
- **Transcription is the weak link:** two transcriptions of the same song agreed only **~41%**;
  tempo estimates differ (92 vs 98 BPM). Wrong notes become wrong notes in the cover.
- **Adherence:** melody present in 62% of a full cover (melody + chords), 85–91% of the first minute
  with "Faithful" sampling (temperature 0.6) — but Faithful can sound restrained.
- **Lyrics** must be supplied and fit the melody's syllables; nothing re-aligns them automatically.
- **Non-commercial:** SheetSage2 weights are CC BY-NC 4.0.
- *Unblock:* better transcription (melody from the isolated vocal + chords from the mix, merged; or a
  newer transcriber), original lyrics via Whisper pre-filled, a model with audio conditioning.

## 4. Restyles and remixes of existing songs (UVR5 + Stable Audio 3)

- **The core trade-off, measured on the full song:** you can keep the original timing *or* change
  the sound a lot — not both.

  | Setting (SA3 Medium) | Timing lock (1.0 = identical, unrelated = 0.07) | Sound change (unrelated = 100%) |
  |---|---|---|
  | strength 0.5, cfg 1 | 0.79–0.82 | 29% |
  | 0.5–0.55, cfg 3–6 (best in sync) | 0.54–0.60 | 39–43% |
  | per-stem prompts, 0.55, cfg 3 | 0.53–0.61 | 42–43% |
  | ≥ 0.65 (with BPM in prompt) | 0.18–0.31 even after shifting | 52–95% |

  Above 0.6 the tempo holds (87.6 BPM with "88 BPM" in the prompt) but the groove is re-composed:
  per-window offsets jump ±600 ms, so it can't simply be shifted back.
- **Listening verdict (user):** the in-sync versions still sound too similar, with **off-tempo
  moments and artifacts**, and not enough genre/mood change.
- **Artifacts stack:** separation (BS-RoFormer/Demucs) → per-stem restyle → recombination compounds
  each stage's artifacts; restyling stems separately makes them disagree with each other.
- **Artist names don't steer SA3** (trained on licensed data) — describe the sound.
- **Small** caps at 2 min per pass (chunked, crossfaded); Medium ~6:10.
- *Unblock:* automatic beat-lock (warp a heavy restyle beat-by-beat onto the original grid — not
  built; may still break phrasing), manual warping in Ableton/Logic, restyling the full mix instead of
  stems, fine-tuned SA3 LoRAs for a target sound (§6), or a stronger audio-conditioned model.

## 5. Voice → instrument

- **YuE2 instrumental cover** already moves the vocal melody to an instrument (prompt e.g. "lead
  electric guitar plays the melody"): coherent, but a new performance, not your exact phrasing.
- **MIDI route:** SheetSage saves `melody.mid`; a DAW guitar + amp gives full control, manual work.
- **Direct timbre transfer** (pitch + loudness of the vocal → guitar, keeping bends and timing) is
  not built; open options (DDSP/RAVE-style) mostly lack good electric-guitar models.

## 6. Hardware, platform and licensing

- **Apple Silicon only, no CUDA.** Much of the ecosystem (official YuE2, LeVo 2, SA3 Medium's
  default path, TensorRT builds) targets NVIDIA; everything here is a port or fallback.
- **This Mac:** no admin rights; Intel Homebrew under Rosetta (MLX needs arm64 Python); the
  Command Line Tools' Swift 5.8 / macOS 13.3 SDK, so the app avoids macOS 14 SwiftUI features.
- **Speed:** LeVo 2 ~5× slower than real time; YuE2 ~1× (a 3-min song ≈ 3 min); SA3 Medium ~15×
  faster than real time.
- **Licenses:** SheetSage2 CC BY-NC; LeVo 2 research/education only; SA3 Stability Community License
  (free under $1M revenue); YuE2 weights per the YuE project's model license. Commercial use of covers
  also needs rights to the original songs.
- **Training:** SA3 has LoRA fine-tuning on MLX (`optimized/mlx` + underfit) — the most promising local
  lever for "sounds like X" — but needs a curated dataset you have rights to.
- *Unblock:* a cloud GPU (NVIDIA) for the official stacks, LoRA training on your own material.

## 7. How we verify

- **Claude can't hear audio.** Everything above is measured (timing correlation, timbre distance,
  melody match via transcription, lyrics via Whisper, level reconstruction) or reported by you.
  Metrics catch drift, bleed and truncation, not taste — final calls need your ears.
- **The self-test drives the app's logic, not its screen**; layout bugs (like the hidden upload
  area) only show when you look.
- Evaluation script: `engine/restyle_eval.py` (timing lock + sound change + per-window offsets).
