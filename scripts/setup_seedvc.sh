#!/bin/zsh
# setup_seedvc.sh — install Seed-VC (zero-shot singing voice conversion) for engine/voice_swap.py.
#   zsh scripts/setup_seedvc.sh
# Installs into ~/Library/Application Support/YuE2Mac/SeedVC (no admin): src/ (Plachtaa/seed-vc),
# venv/ (Python 3.10 via uv) and hf/ (model cache, ~1.5 GB on first use). Two Apple-Silicon fixes are
# applied to inference.py: the F0 tensors are float32 (MPS has no float64), and the BigVGAN vocoder
# runs on the CPU (its grouped convolutions exceed an MPS size limit on long chunks). On Linux/CUDA
# the same patches are harmless. Seed-VC is GPL-3.0.
set -e
BASE="$HOME/Library/Application Support/YuE2Mac/SeedVC"
[[ "$(uname)" == Linux ]] && BASE="${XDG_DATA_HOME:-$HOME/.local/share}/YuE2Mac/SeedVC"
UV=$(command -v uv || echo "$HOME/.local/bin/uv")
mkdir -p "$BASE"
[ -d "$BASE/src" ] || git clone -q https://github.com/Plachtaa/seed-vc.git "$BASE/src"
cd "$BASE/src"
"$UV" venv -q --allow-existing --python 3.10 "$BASE/venv"
# The upstream requirements use per-line index flags uv can't parse; install torch explicitly.
grep -v -E "^(--|torch|gradio|FreeSimpleGUI|sounddevice)" requirements-mac.txt > "$BASE/reqs.txt"
# (PyPI's Linux torch wheels already include CUDA, so the same line serves an NVIDIA box.)
"$UV" pip install -q --python "$BASE/venv/bin/python" "torch==2.5.1" "torchaudio==2.5.1" -r "$BASE/reqs.txt"
python3 - <<'E'
from pathlib import Path
p = Path("inference.py"); s = p.read_text()
s = s.replace("torch.from_numpy(F0_ori).to(device)", "torch.from_numpy(F0_ori).float().to(device)")
s = s.replace("torch.from_numpy(F0_alt).to(device)", "torch.from_numpy(F0_alt).float().to(device)")
old = "        vc_wave = vocoder_fn(vc_target.float()).squeeze()"
if old in s and "BigVGAN's grouped convs" not in s:
    s = s.replace(old, """        if device.type == "mps":  # BigVGAN's grouped convs exceed an MPS size limit on long chunks
            vc_wave = vocoder_fn.cpu()(vc_target.float().cpu()).squeeze().to(device)
        else:
            vc_wave = vocoder_fn(vc_target.float()).squeeze()""")
p.write_text(s)
E
"$BASE/venv/bin/python" -c "import torch; print('▸ Seed-VC ready · torch', torch.__version__, '· mps', torch.backends.mps.is_available(), '· cuda', torch.cuda.is_available())"
