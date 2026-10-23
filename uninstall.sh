#!/usr/bin/env bash
# Remove LyricPill: the app, its lyric cache, its settings, and any legacy LaunchAgent.
set -euo pipefail

BUNDLE_ID="io.github.theranjithjayaram.lyric-pill"
PROCESS_PATTERN='LyricPill.app/Contents/MacOS/LyricPill'

echo "==> Quitting LyricPill"
pkill -f "$PROCESS_PATTERN" 2>/dev/null || true

for label in "$BUNDLE_ID" local.spotify-lyrics-overlay; do
    plist="$HOME/Library/LaunchAgents/$label.plist"
    [ -f "$plist" ] || continue
    echo "==> Removing legacy LaunchAgent $label"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
done

echo "==> Removing the app, cache and settings"
rm -rf "/Applications/LyricPill.app" "$HOME/Applications/LyricPill.app" \
       "$HOME/Applications/SpotifyLyricsOverlay.app"
rm -rf "$HOME/Library/Caches/lyric-pill" "$HOME/Library/Caches/spotify-lyrics-overlay"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo
echo "Done."
echo "  • If LyricPill still appears in System Settings → General → Login Items, remove it there."
echo "  • The Hindi → English language pack, if downloaded, is managed by macOS:"
echo "    System Settings → General → Language & Region → Translation Languages."
