#!/usr/bin/env bash
# Remove LyricPill: the app, its lyric cache and its settings.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$REPO/app/Info.plist")"
APP_NAME="LyricPill.app"
PROCESS_PATTERN='LyricPill.app/Contents/MacOS/LyricPill'

echo "==> Quitting LyricPill"
pkill -f "$PROCESS_PATTERN" 2>/dev/null || true

echo "==> Removing the app, cache and settings"
rm -rf "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME" "$HOME/Library/Caches/lyric-pill"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo
echo "Done."
echo "  • If LyricPill still appears in System Settings → General → Login Items, remove it there."
echo "  • Downloaded language packs are managed by macOS:"
echo "    System Settings → General → Language & Region → Translation Languages."
