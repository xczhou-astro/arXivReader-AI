#!/bin/zsh
set -euo pipefail

project_root="${0:A:h}/.."
app_delegate="$project_root/macos/Runner/AppDelegate.swift"
info_plist="$project_root/macos/Runner/Info.plist"

if ! /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$info_plist" | rg -x 'false' >/dev/null; then
  print -u2 'Expected the app to be visible in the Dock.'
  exit 1
fi

if ! rg -F 'NSApp.setActivationPolicy(.regular)' "$app_delegate" >/dev/null; then
  print -u2 'Expected the app to use the regular activation policy.'
  exit 1
fi

if rg -F 'NSStatusItem' "$app_delegate" >/dev/null; then
  print -u2 'Expected no custom menu-bar status item.'
  exit 1
fi

if ! rg -F 'return false' "$app_delegate" >/dev/null; then
  print -u2 'Expected closing the main window not to terminate the app.'
  exit 1
fi
