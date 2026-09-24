#!/bin/zsh
# bakeoff_eval.sh — score covers/versions of a song on every axis we can measure.
#   zsh engine/bakeoff_eval.sh ORIGINAL.wav REFERENCE_SCORE.abc LYRICS.txt LANG UNRELATED.wav VERSION.wav…
# melody  : share of the reference melody recognisably present (SheetSage transcription + melody_match)
# timing  : onset-envelope lock vs the original (1.0 identical, unrelated ≈ 0.07)
# change  : timbre distance vs the original as % of an unrelated song
# lyrics  : words of LYRICS.txt heard (Whisper on the isolated vocal)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Library/Application Support/YuE2Mac"
SS="$APP/SheetSage"; SEP="$APP/Separator/venv/bin/python"; FF=$(for f in ~/.pixi/bin/ffmpeg /opt/homebrew/bin/ffmpeg; do [ -x "$f" ] && echo "$f" && break; done)
ORIG="$1"; REF="$2"; LYR="$3"; LANG="$4"; UNREL="$5"; shift 5
WORK=$(mktemp -d)
printf "%-34s %8s %8s %8s %10s\n" version melody timing change lyrics
for v in "$@"; do
  name=$(basename "$v" .wav)
  "$SS/venv/bin/python" "$HERE/transcribe.py" "$v" --models "$SS/models" --output "$WORK/$name-tx" --ffmpeg "$FF" >/dev/null 2>&1 || true
  mel=$(python3 "$HERE/melody_match.py" "$REF" "$WORK/$name-tx/score.abc" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['coverage']*100:.0f}%\")" 2>/dev/null || echo "?")
  metrics=$("$SEP" -c "
import sys; sys.path.insert(0,'$HERE'); import restyle_eval as r
e0,m0=r.feats('$ORIG'); secs=len(e0)/r.FPS; _,mu=r.feats('$UNREL',secs); e,m=r.feats('$v',secs)
t,_=r.timing(e0,e); print(f'{t:.2f} {r.timbre_distance(m0,m)/r.timbre_distance(m0,mu)*100:.0f}%')" 2>/dev/null)
  lyr=$(HF_HUB_OFFLINE=1 "$SS/venv/bin/python" "$HERE/audio_tools.py" --models "$SS/models" --ffmpeg "$FF" lyrics "$v" --lyrics-file "$LYR" --isolate --language "$LANG" --work "$WORK" 2>&1 | grep '^\[result\]' | sed 's/^\[result\] //' | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['words_found']}/{d['words_intended']}\")" 2>/dev/null || echo "?")
  printf "%-34s %8s %8s %8s %10s\n" "$name" "$mel" "${metrics% *}" "${metrics#* }" "$lyr"
done
rm -rf "$WORK"
