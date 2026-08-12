#!/bin/bash
# Builds OpenCharm (Release) and copies the app bundle into dist/ at the repo root.
# Usage: Tools/build-dist.sh  (or `make dist`)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
DIST="$ROOT/dist"

cd "$ROOT"

# Model weights + project generation (idempotent).
Tools/fetch-rnnoise-model.sh
xcodegen

# ONLY_ACTIVE_ARCH: the CRNNoise x86 AVX paths don't build in a universal Release slice on
# Apple silicon; ship the native arch (same policy as the Debug builds).
xcodebuild \
    -project OpenCharm.xcodeproj \
    -scheme OpenCharm \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -quiet \
    build \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES

APP="$DERIVED/Build/Products/Release/OpenCharm.app"
BIN="$APP/Contents/MacOS/OpenCharm"
if [ ! -x "$BIN" ]; then
    echo "error: build product missing or has no executable at $BIN" >&2
    exit 1
fi

mkdir -p "$DIST"
rm -rf "$DIST/OpenCharm.app"
# ditto preserves the bundle structure, resource forks, and symlinks (cp -r can mangle .apps).
ditto "$APP" "$DIST/OpenCharm.app"

echo "✓ dist/OpenCharm.app ($(du -sh "$DIST/OpenCharm.app" | cut -f1))"
