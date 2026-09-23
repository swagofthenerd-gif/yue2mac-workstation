#!/bin/zsh
# setup_separator.sh — UVR5 models (BS-RoFormer, MelBand-RoFormer, Demucs v4 ft) via audio-separator,
# in their own Python environment with Apple GPU (MPS) support. No admin rights needed.
set -e
SEP="$HOME/Library/Application Support/YuE2Mac/Separator"
PY=$(ls -d ~/.local/share/uv/python/cpython-3.12*-macos-aarch64-none/bin/python3.12 2>/dev/null | head -1)
[ -n "$PY" ] || { uv python install 3.12; PY=$(ls -d ~/.local/share/uv/python/cpython-3.12*-macos-aarch64-none/bin/python3.12 | head -1); }
mkdir -p "$SEP/models"
[ -x "$SEP/venv/bin/python" ] || "$PY" -m venv "$SEP/venv"
"$SEP/venv/bin/pip" install -q --upgrade pip
"$SEP/venv/bin/pip" install -q "audio-separator[cpu]==0.47.0" audioread soundfile
# Fetch the two default models now so the first split doesn't pause to download.
for m in model_bs_roformer_ep_317_sdr_12.9755.ckpt htdemucs_ft.yaml; do
  "$SEP/venv/bin/audio-separator" --download_model_only -m "$m" --model_file_dir "$SEP/models" >/dev/null 2>&1
done
"$SEP/venv/bin/python" -c "import torch; print('✓ Separator ready · Apple GPU:', torch.backends.mps.is_available())"
