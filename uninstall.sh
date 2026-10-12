#!/usr/bin/env bash
set -euo pipefail

AGENT_PLIST="$HOME/Library/LaunchAgents/io.github.theranjithjayaram.lyric-pill.plist"

echo "==> Stopping and removing LyricPill"
launchctl unload "$AGENT_PLIST" 2>/dev/null || true
rm -f "$AGENT_PLIST"
pkill -x LyricPill 2>/dev/null || true
rm -rf "$HOME/Applications/LyricPill.app"
rm -rf "$HOME/Library/Caches/lyric-pill"
defaults delete io.github.theranjithjayaram.lyric-pill 2>/dev/null || true

echo "Done. (The Hindi→English language pack, if downloaded, is managed by"
echo "macOS — remove it in System Settings → General → Language & Region.)"
