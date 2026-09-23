#!/bin/zsh
# setup_stable_audio3.sh — Stable Audio 3 (Stability AI) for the Remix mode, in its own environment.
#
# The weights are gated. Once, on huggingface.co (free account):
#   1. accept the license on  https://huggingface.co/stabilityai/stable-audio-3-small-music
#      (and stable-audio-3-medium if you want to try Medium)
#   2. accept the Gemma terms on https://huggingface.co/google/t5gemma-b-b-ul2  (its text encoder)
#   3. run this script; it asks you to log in (`hf auth login`) if you aren't yet.
# License: Stability AI Community License (free incl. commercial use under $1M revenue).
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
B="$HOME/Library/Application Support/YuE2Mac/StableAudio3"
mkdir -p "$B"
[ -d "$B/src/.git" ] || git clone -q https://github.com/Stability-AI/stable-audio-3.git "$B/src"
cd "$B/src"
UV_PROJECT_ENVIRONMENT="$B/venv" uv sync -q --python 3.12
HF="$B/venv/bin/hf"
if [ -n "$HF_LOGIN_TOKEN" ]; then
  "$HF" auth login --token "$HF_LOGIN_TOKEN" >/dev/null 2>&1 || { echo "That Hugging Face token was refused."; exit 1; }
fi
if ! "$HF" auth whoami >/dev/null 2>&1; then
  if [ -t 0 ]; then "$HF" auth login; else echo "Log in to Hugging Face first (paste a read token in Settings)."; exit 1; fi
fi
MODEL="${SA3_MODEL:-small-music}"
"$B/venv/bin/python" "$SCRIPT_DIR/../engine/remix.py" fetch --model "$MODEL" 2>&1 | grep -vE "flash_attn|No module named 'flash" | tail -2
echo "✓ Stable Audio 3 ($MODEL) ready"
