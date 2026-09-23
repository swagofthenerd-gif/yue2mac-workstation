# Setting up the workstation on a Mac

Everything here runs locally on an Apple Silicon Mac (M1 or newer). Nothing needs admin rights
unless noted. Plan on roughly **20 GB** of disk: about 7 GB for the full-quality model, 8 GB for Cover
Mode's tools, plus room for songs.

## 1. Get the code

```bash
git clone https://github.com/swagofthenerd-gif/yue2mac-workstation.git ~/YuE2Mac
cd ~/YuE2Mac
```

## 2. Build the app

**With the Command Line Tools only (no Xcode, no Apple ID):**

```bash
xcode-select --install            # once, if `swiftc` isn't available yet
zsh scripts/build_app.sh --install  # builds build/YuE2Mac.app and copies it to ~/Applications
```

The code deliberately avoids macOS 14-only SwiftUI features (`@Observable`, `#Preview`, …) so it
compiles with the older Swift 5.8 / macOS 13.3 SDK in the Command Line Tools. Keep it that way: use
`ObservableObject` + `@Published`.

**With Xcode:** `YuE2Mac.xcodeproj` still opens, but new files added since the fork
(`Core/Workstation.swift`, `SideTasks.swift`, `Exporter.swift`, `HumRecorder.swift`,
`CoverModeInstaller.swift`, `SelfTest.swift`, the new Views, `Resources/abcjs`, `engine/`) are **not in
the Xcode project**. `scripts/build_app.sh` is the supported build.

## 3. The music engine (first launch)

Open **YuE2Mac** and press **Download & Install**. It creates a Python environment in
`~/Library/Application Support/YuE2Mac/Python` and downloads the YuE2 MLX model (pick **bf16**, the
unquantized one, on Macs with 32 GB+).

**Watch out — this is what went wrong on the work Mac:** the app builds that environment from the first
Python it finds, and an *Intel* Homebrew (`/usr/local`, running under Rosetta) gives an Intel Python
that MLX can't use. If setup fails with "MLX won't import", create the environment yourself from an
Apple Silicon Python before pressing Install:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh     # installs uv in your home folder
uv python install 3.12
~/.local/share/uv/python/cpython-3.12*-macos-aarch64-none/bin/python3.12 -m venv \
  "$HOME/Library/Application Support/YuE2Mac/Python"
```

The app skips creating the environment when one already exists, and installs MLX into it.

## 4. Cover Mode, stems and lyrics check

In the app: **Settings (gear) → Install Cover Mode.** It needs an Apple Silicon Python 3.10 or 3.11
(install with `uv python install 3.11` if missing) and sets up, in
`~/Library/Application Support/YuE2Mac/SheetSage`:

- SheetSage2 + MERT-v2-FullSong (audio → score), pinned libraries (torch 2.8, transformers 4.45.2, numpy 1.24.3)
- Demucs 4.1 (stems / vocal isolation) and mlx-whisper with Whisper large-v3-turbo (lyrics check)

**ffmpeg** must be installed for covers and exports; the app looks in `~/.pixi/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`. (`brew install ffmpeg` on an Apple Silicon Homebrew is fine.)

**AI score edits** use the Claude Code CLI (`~/.local/bin/claude`), signed in to your account.

## 5. Command line

```bash
ln -sf ~/YuE2Mac/scripts/yue2mac ~/.local/bin/yue2mac
yue2mac            # usage
yue2mac song --style "indie pop, 100 BPM" --lyrics-file lyrics.txt --takes 2
yue2mac cover song.mp3 --style "bossa nova, soft female vocal" --lyrics-file lyrics.txt
```

## 6. Checking a build without clicking through it

```bash
B=build/YuE2Mac.app/Contents/MacOS/YuE2Mac
$B --selftest /tmp/quick.json some-clip.m4a                          # transcribe, 2 takes, plan, export
YUE2MAC_SELFTEST=cancel $B --selftest /tmp/cancel.json               # Stop button leaves nothing behind
YUE2MAC_SELFTEST=full   $B --selftest /tmp/full.json                 # one normal-length song
YUE2MAC_SELFTEST=tools YUE2MAC_SELFTEST_SONG="<a song folder>" $B --selftest /tmp/tools.json clip.m4a
```

The self-test uses a separate settings suite, so it never touches your real settings. It can't see
layout — always look at new screens yourself.

## Where things live

| What | Where |
|---|---|
| Swift app | `YuE2Mac/` (Core = logic, Views = screens) |
| Python engine (bundled into the app) | `engine/` — `yue2mac_engine.py`, `transcribe.py`, `audio_tools.py`, `score_editor.py`, `abc_tools.py` |
| Downloaded model code (never edited) | `~/Library/Application Support/YuE2Mac/Scripts` |
| Songs (one folder each, `song.json` + takes + `score.abc`) | `~/Library/Application Support/YuE2Mac/Output` |
