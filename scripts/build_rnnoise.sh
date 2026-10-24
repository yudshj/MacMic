#!/bin/bash
# Builds a static, NEON-optimised RNNoise (xiph/rnnoise, BSD-3-Clause) for Apple Silicon.
#
# Output (gitignored except the header):
#   third_party/rnnoise/lib/librnnoise.a
#   third_party/rnnoise/include/rnnoise.h
#
# The model weights ship as a ~78 MB generated C file, so they are downloaded at build
# time (pinned by sha256) instead of being committed.
#
# Env:
#   RNNOISE_SRC=/path/to/existing/rnnoise/checkout   reuse a checkout (skips clone/download
#                                                    when it already has src/rnnoise_data.c)
#   RNNOISE_MODEL=little|default                     which weights to embed (default: little).
#       Measured on M5 Pro, speech + noise @ 5 dB SNR: little = 1.7 % of one core, 11.3 dB out;
#       default = 4.4 % of one core, 11.7 dB out. Same API, same latency.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/rnnoise"
LIB="$OUT/lib/librnnoise.a"

RNNOISE_REPO="https://github.com/xiph/rnnoise.git"
RNNOISE_COMMIT="70f1d256acd4b34a572f999a05c87bf00b67730d"   # 2025-02-22, post v0.2
MODEL_SHA256="0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37"
MODEL_URL="https://media.xiph.org/rnnoise/models/rnnoise_data-${MODEL_SHA256}.tar.gz"

if [[ -f "$LIB" && "${1:-}" != "--force" ]]; then
    echo "✅ RNNoise already built: $LIB"
    exit 0
fi

SRC="${RNNOISE_SRC:-$ROOT/third_party/rnnoise-src}"
if [[ ! -d "$SRC/.git" && ! -f "$SRC/src/denoise.c" ]]; then
    echo "📥 Cloning xiph/rnnoise @ ${RNNOISE_COMMIT:0:8}..."
    git clone --quiet "$RNNOISE_REPO" "$SRC"
fi
if [[ -d "$SRC/.git" ]]; then
    git -C "$SRC" fetch --quiet origin "$RNNOISE_COMMIT" 2>/dev/null || true
    git -C "$SRC" -c advice.detachedHead=false checkout --quiet "$RNNOISE_COMMIT"
fi

if [[ ! -f "$SRC/src/rnnoise_data.c" ]]; then
    echo "📥 Downloading RNNoise model weights (~60 MB)..."
    TARBALL="$(mktemp -t rnnoise_data).tar.gz"
    curl -fL --retry 3 -o "$TARBALL" "$MODEL_URL"
    echo "$MODEL_SHA256  $TARBALL" | shasum -a 256 -c -
    tar -xzf "$TARBALL" -C "$SRC"
    rm -f "$TARBALL"
fi

echo "🔨 Compiling RNNoise (arm64, -O3, NEON)..."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
MODEL="${RNNOISE_MODEL:-little}"
case "$MODEL" in
    little)  DATA_SRC="rnnoise_data_little" ;;
    default) DATA_SRC="rnnoise_data" ;;
    *) echo "RNNOISE_MODEL must be little or default" >&2; exit 1 ;;
esac
echo "   model: $MODEL"
FILES=(denoise rnn pitch kiss_fft celt_lpc nnet nnet_default parse_lpcnet_weights rnnoise_tables "$DATA_SRC")
for f in "${FILES[@]}"; do
    clang -O3 -mcpu=apple-m1 -target arm64-apple-macos12.0 -fPIC -DNDEBUG \
        -I"$SRC/include" -I"$SRC/src" -c "$SRC/src/$f.c" -o "$BUILD/$f.o" &
done
wait

mkdir -p "$OUT/lib" "$OUT/include"
rm -f "$LIB"
ar rcs "$LIB" "$BUILD"/*.o
cp "$SRC/include/rnnoise.h" "$OUT/include/rnnoise.h"
cp "$SRC/COPYING" "$OUT/COPYING"
echo "✅ Built $LIB ($(du -h "$LIB" | cut -f1))"
