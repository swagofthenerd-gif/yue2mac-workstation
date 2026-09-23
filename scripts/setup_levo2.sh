#!/bin/zsh
# setup_levo2.sh — builds LeVo 2 (Tencent SongGeneration 2) for Apple Silicon and downloads
# its weights into the app's folder. No admin rights or Xcode needed.
#
#   zsh scripts/setup_levo2.sh            # large model, 8-bit (5.3 GB) — the tested default
#   LEVO_SIZE=medium zsh scripts/setup_levo2.sh
#
# Uses the community C++/GGML port ckadirt/LeVo2.cpp pinned to a tested commit, plus
# patches/levo2cpp-metal-causal-mask.patch: that ggml build has no DIAG_MASK_INF on Metal,
# so the patch builds the causal mask from arange/sub/step and passes it to soft_max_ext.
# Without it the GPU aborts and the CPU path is ~28x slower than real time.
#
# LICENSE: LeVo 2 weights and this port are for research, academic and education use only.
# Commercial and production use are prohibited by Tencent's SongGeneration terms.
set -e
cd "$(dirname "$0")/.."
REPO_DIR="$PWD"
BASE="$HOME/Library/Application Support/YuE2Mac/LeVo2"
SRC="$BASE/src"
COMMIT=cfd1635beb5ab400b1c8780a7cfd8eb0629bcafe
SIZE="${LEVO_SIZE:-large}"

command -v cmake >/dev/null || uv tool install cmake
command -v ninja >/dev/null || uv tool install ninja

echo "▸ Source (LeVo2.cpp @ ${COMMIT:0:7})"
if [ ! -d "$SRC/.git" ]; then
  git clone -q --recurse-submodules https://github.com/ckadirt/LeVo2.cpp.git "$SRC"
fi
git -C "$SRC" fetch -q origin
git -C "$SRC" checkout -q "$COMMIT"
git -C "$SRC" submodule update -q --init --recursive
git -C "$SRC" checkout -q -- src
git -C "$SRC" apply "$REPO_DIR/patches/levo2cpp-metal-causal-mask.patch"

echo "▸ Building with Metal (Apple GPU)…"
cmake -S "$SRC" -B "$SRC/build-metal" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=ON >/dev/null
cmake --build "$SRC/build-metal" -j 16 >/dev/null
# The binaries find their ggml dylibs through rpaths into the build tree, so link, don't copy.
rm -rf "$BASE/bin"; ln -s "$SRC/build-metal/bin" "$BASE/bin"

echo "▸ GPU check"
"$BASE/bin/levo-cli" --smoke gpu 2>/dev/null | tail -1

echo "▸ Weights (ckadirt/LeVo2-GGUF: ${SIZE} Q8_0, flow Q8_0, VAE F32)"
uv run --quiet --with "huggingface_hub>=0.30" python - "$BASE/models" "$SIZE" <<'PY'
import sys
from huggingface_hub import snapshot_download
out, size = sys.argv[1], sys.argv[2]
snapshot_download(repo_id="ckadirt/LeVo2-GGUF", local_dir=out,
                  allow_patterns=[f"LeVo2-v2-{size}-Q8_0.gguf*", "LeVo2-v2-flow-Q8_0.gguf*",
                                  "LeVo2-v2-vae-F32.gguf*", "LICENSE", "THIRD_PARTY_NOTICES.md"])
PY
cd "$BASE/models"
for f in "LeVo2-v2-${SIZE}-Q8_0" LeVo2-v2-flow-Q8_0 LeVo2-v2-vae-F32; do
  [ "$(shasum -a 256 $f.gguf | awk '{print $1}')" = "$(awk '{print $1}' $f.gguf.sha256)" ] && echo "  $f ✓" || { echo "  $f checksum MISMATCH"; exit 1; }
done
echo "✓ LeVo 2 ready in $BASE"
