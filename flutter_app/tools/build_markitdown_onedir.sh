#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$APP_ROOT/build/markitdown_pyinstaller"
DIST_ROOT="$BUILD_ROOT/dist"
RESOURCE_ROOT="$APP_ROOT/macos/Runner/Resources/arxiv_markitdown"

rm -rf "$BUILD_ROOT" "$RESOURCE_ROOT"
mkdir -p "$BUILD_ROOT" "$(dirname "$RESOURCE_ROOT")"

conda run -n ai pyinstaller \
  --clean \
  --noconfirm \
  --onedir \
  --target-arch arm64 \
  --name arxiv_markitdown \
  --collect-all magika \
  --distpath "$DIST_ROOT" \
  --workpath "$BUILD_ROOT/work" \
  --specpath "$BUILD_ROOT" \
  "$APP_ROOT/tools/markitdown_converter.py"

/usr/bin/ditto "$DIST_ROOT/arxiv_markitdown" "$RESOURCE_ROOT"
chmod 755 "$RESOURCE_ROOT/arxiv_markitdown"

echo "Bundled MarkItDown helper at $RESOURCE_ROOT"
