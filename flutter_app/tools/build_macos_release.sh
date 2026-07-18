#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_ROOT="${ARXIVREADER_BUILD_VENV:-$APP_ROOT/.build-venv}"
VENV_PYTHON="$VENV_ROOT/bin/python"
PYTHON_BIN="${PYTHON3_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null; then
  echo 'Python 3 is required. Install Python 3, then run this script again.' >&2
  exit 1
fi

if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo 'Python 3.10 or later is required for Microsoft MarkItDown.' >&2
  echo 'Install a current Python from python.org, then set PYTHON3_BIN if needed.' >&2
  exit 1
fi

if [[ -x "$VENV_PYTHON" ]] && ! "$VENV_PYTHON" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  rm -rf "$VENV_ROOT"
fi

if [[ ! -x "$VENV_PYTHON" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_ROOT"
fi

"$VENV_PYTHON" -m pip install --upgrade pip
"$VENV_PYTHON" -m pip install --upgrade 'markitdown[pdf]>=0.1.0' pyinstaller

MARKITDOWN_PYTHON="$VENV_PYTHON" "$APP_ROOT/tools/build_markitdown_onedir.sh"

cd "$APP_ROOT"
flutter pub get
flutter build macos --release

echo 'Release app: build/macos/Build/Products/Release/ArxivReader AI.app'
