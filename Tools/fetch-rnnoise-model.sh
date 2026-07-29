#!/usr/bin/env bash
# Fetches the RNNoise trained-model weights (rnnoise_data.c) that upstream
# xiph/rnnoise generates via its own download_model.sh. We do not vendor this
# ~74 MB generated C file in git; instead we fetch and checksum-verify it at
# build time, mirroring upstream's own approach.
#
# Pinned to the exact archive used when this repo's vendored RNNoise sources
# were captured (xiph/rnnoise @ main, commit
# 70f1d256acd4b34a572f999a05c87bf00b67730d). The hash below is copied
# verbatim from that commit's `model_version` file and doubles as the
# archive's own sha256 (upstream names the tarball after its checksum).
set -euo pipefail

MODEL_HASH="0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37"
MODEL_URL="https://media.xiph.org/rnnoise/models/rnnoise_data-${MODEL_HASH}.tar.gz"
# sha256 of src/rnnoise_data.c *inside* that archive — pins the actual
# artifact we place in the tree, not just the tarball around it.
DATA_C_SHA256="d6021b7697677c4d2274c912975e143765552b0e6f25500aa660fdb4a9849be5"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/Packages/AudioPipeline/Sources/CRNNoise/rnnoise_data.c"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [ -f "$DEST" ] && [ "$(sha256 "$DEST")" = "$DATA_C_SHA256" ]; then
  echo "fetch-rnnoise-model: $DEST already present and verified, skipping."
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

ARCHIVE="$WORKDIR/rnnoise_data-${MODEL_HASH}.tar.gz"
echo "fetch-rnnoise-model: downloading $MODEL_URL"
curl -fLsS --retry 3 -o "$ARCHIVE" "$MODEL_URL"

ACTUAL_ARCHIVE_SHA="$(sha256 "$ARCHIVE")"
if [ "$ACTUAL_ARCHIVE_SHA" != "$MODEL_HASH" ]; then
  echo "fetch-rnnoise-model: ERROR archive checksum mismatch (got $ACTUAL_ARCHIVE_SHA, expected $MODEL_HASH)." >&2
  echo "fetch-rnnoise-model: refusing to use a corrupted/unexpected download." >&2
  exit 1
fi

tar -xzf "$ARCHIVE" -C "$WORKDIR" src/rnnoise_data.c

ACTUAL_DATA_SHA="$(sha256 "$WORKDIR/src/rnnoise_data.c")"
if [ "$ACTUAL_DATA_SHA" != "$DATA_C_SHA256" ]; then
  echo "fetch-rnnoise-model: ERROR extracted rnnoise_data.c checksum mismatch (got $ACTUAL_DATA_SHA, expected $DATA_C_SHA256)." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp "$WORKDIR/src/rnnoise_data.c" "$DEST"
echo "fetch-rnnoise-model: wrote $DEST ($(wc -c < "$DEST" | tr -d ' ') bytes), checksum verified."
