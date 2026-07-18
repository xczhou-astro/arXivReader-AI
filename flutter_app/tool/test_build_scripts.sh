#!/usr/bin/env bash
set -euo pipefail

app_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper_script="$app_root/tools/build_markitdown_onedir.sh"
release_script="$app_root/tools/build_macos_release.sh"

if rg -n '\bconda\b' "$helper_script" "$release_script" 2>/dev/null; then
  echo 'Build scripts must not require Conda.' >&2
  exit 1
fi

if [[ ! -f "$release_script" ]]; then
  echo 'Expected a one-command macOS release build script.' >&2
  exit 1
fi

if ! rg -F -- '-m venv' "$release_script" >/dev/null; then
  echo 'Expected the release script to create an isolated Python venv.' >&2
  exit 1
fi

if ! rg -F 'Python 3.10 or later is required' "$release_script" >/dev/null; then
  echo 'Expected the release script to reject unsupported system Python versions.' >&2
  exit 1
fi

if ! rg -F 'markitdown[pdf]>=0.1.0' "$release_script" >/dev/null; then
  echo 'Expected the release script to install the supported MarkItDown package.' >&2
  exit 1
fi

if ! rg -F 'build_markitdown_onedir.sh' "$release_script" >/dev/null; then
  echo 'Expected the release script to bundle MarkItDown.' >&2
  exit 1
fi

if ! rg -F 'flutter build macos --release' "$release_script" >/dev/null; then
  echo 'Expected the release script to build the macOS app.' >&2
  exit 1
fi
