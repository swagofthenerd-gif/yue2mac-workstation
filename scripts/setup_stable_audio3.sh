#!/bin/zsh
# setup_stable_audio3.sh — Stable Audio 3 for the Remix mode, using Stability's official Apple-GPU
# (MLX) runtime from the stable-audio-3 repo (optimized/mlx). No admin rights needed.
#
# The weights are gated. Once, on huggingface.co (free account):
#   accept the license on https://huggingface.co/stabilityai/stable-audio-3-optimized
# then run this script; it asks you to log in (`hf auth login`) if you aren't yet, or takes a
# read token from $HF_LOGIN_TOKEN. Downloads Medium (best, ≈3 GB) and Small (≈1 GB).
# The text encoder (T5Gemma, Gemma terms) ships converted inside that repo.
# License: Stability AI Community License (free incl. commercial use under $1M revenue).
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
B="$HOME/Library/Application Support/YuE2Mac/StableAudio3"
mkdir -p "$B"
[ -d "$B/src/.git" ] || git clone -q https://github.com/Stability-AI/stable-audio-3.git "$B/src"
git -C "$B/src" pull -q --ff-only || true
MLX="$B/src/optimized/mlx"
(cd "$MLX" && ./install.sh -y >/dev/null)
HF="$MLX/.venv/bin/hf"
[ -x "$HF" ] || "$MLX/.venv/bin/python" -m pip install -q "huggingface_hub[cli]"
if [ -n "$HF_LOGIN_TOKEN" ]; then
  "$HF" auth login --token "$HF_LOGIN_TOKEN" >/dev/null 2>&1 || { echo "That Hugging Face token was refused."; exit 1; }
fi
if ! "$HF" auth whoami >/dev/null 2>&1; then
  if [ -t 0 ]; then "$HF" auth login; else echo "Log in to Hugging Face first (paste a read token in Settings)."; exit 1; fi
fi
FF=$(for f in ~/.pixi/bin/ffmpeg /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do [ -x "$f" ] && echo "$f" && break; done)
for m in medium small-music; do
  echo "Downloading Stable Audio 3 $m…"
  "$MLX/.venv/bin/python" "$SCRIPT_DIR/../engine/remix.py" fetch --model $m --ffmpeg "${FF:-ffmpeg}" 2>&1 | tail -1
done
echo "✓ Stable Audio 3 (Medium + Small, Apple GPU) ready"
