#!/bin/zsh
set -euo pipefail

project_root="${0:A:h}/.."
app_delegate="$project_root/macos/Runner/AppDelegate.swift"
info_plist="$project_root/macos/Runner/Info.plist"
project_file="$project_root/macos/Runner.xcodeproj/project.pbxproj"

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

if rg -F 'DEVELOPMENT_TEAM =' "$project_file" >/dev/null; then
  print -u2 'Expected the shared Xcode project not to pin a developer team.'
  exit 1
fi

if rg -F 'CODE_SIGN_IDENTITY = "Apple Development"' "$project_file" >/dev/null; then
  print -u2 'Expected the shared Xcode project to use ad-hoc signing by default.'
  exit 1
fi
