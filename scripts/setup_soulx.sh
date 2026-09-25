#!/bin/zsh
# setup_soulx.sh — install SoulX-Singer-SVC (zero-shot singing voice conversion) for engine/soulx_swap.py.
#   zsh scripts/setup_soulx.sh
# Installs into ~/Library/Application Support/YuE2Mac/SoulX (Linux: ~/.local/share/YuE2Mac/SoulX):
# src/ (Soul-AILab/SoulX-Singer, Apache-2.0), venv/ (Python 3.10 via uv) and, in src/pretrained_models,
# only what conversion needs: model-svc.pt (2.8 GB) and the RMVPE pitch tracker (181 MB), plus
# openai/whisper-base in hf/. The upstream requirements pull CUDA-only and transcription packages
# that conversion doesn't use, so a minimal set is installed. One Apple-Silicon fix: the Whisper
# encoder resamples on the CPU (MPS rejects that convolution size) and moves back to the device.
set -e
BASE="$HOME/Library/Application Support/YuE2Mac/SoulX"
[[ "$(uname)" == Linux ]] && BASE="${XDG_DATA_HOME:-$HOME/.local/share}/YuE2Mac/SoulX"
UV=$(command -v uv || echo "$HOME/.local/bin/uv")
mkdir -p "$BASE"
[ -d "$BASE/src" ] || git clone -q https://github.com/Soul-AILab/SoulX-Singer.git "$BASE/src"
cd "$BASE/src"
"$UV" venv -q --allow-existing --python 3.10 "$BASE/venv"
"$UV" pip install -q --python "$BASE/venv/bin/python" "torch==2.5.1" "torchaudio==2.5.1" "transformers==4.41.2" \
  "accelerate==1.11.0" "omegaconf==2.3.0" "librosa==0.11.0" soundfile "scipy==1.15.3" "numpy<2" einops \
  "rotary_embedding_torch==0.8.9" beartype ml_collections tqdm huggingface_hub
export HF_HOME="$BASE/hf"
"$BASE/venv/bin/hf" download Soul-AILab/SoulX-Singer model-svc.pt config.yaml --local-dir pretrained_models/SoulX-Singer
"$BASE/venv/bin/hf" download Soul-AILab/SoulX-Singer-Preprocess rmvpe/rmvpe.pt --local-dir pretrained_models/SoulX-Singer-Preprocess
"$BASE/venv/bin/hf" download openai/whisper-base >/dev/null
python3 - <<'E'
from pathlib import Path
p = Path("soulxsinger/models/modules/whisper_encoder.py"); s = p.read_text()
old = "        wav = torchaudio.functional.resample(wav, orig_freq=sr, new_freq=self.fe.sampling_rate) if sr != self.fe.sampling_rate else wav"
if old in s:
    s = s.replace(old, "        dev = wav.device\n        wav = torchaudio.functional.resample(wav.cpu(), orig_freq=sr, new_freq=self.fe.sampling_rate) if sr != self.fe.sampling_rate else wav  # CPU: MPS conv size limit")
    s = s.replace("input_features.to(wav.device)", "input_features.to(dev)").replace("self.model.device != wav.device", "self.model.device != dev")
    s = s.replace("self.model.to(wav.device)", "self.model.to(dev)").replace("inputs.attention_mask.to(wav.device)", "inputs.attention_mask.to(dev)")
    p.write_text(s)
E
"$BASE/venv/bin/python" -c "import torch; print('▸ SoulX-Singer-SVC ready · torch', torch.__version__, '· mps', torch.backends.mps.is_available(), '· cuda', torch.cuda.is_available())"
