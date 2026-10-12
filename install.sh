#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/LyricPill.app"
AGENT_LABEL="io.github.theranjithjayaram.lyric-pill"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

# Migrate from the pre-release install name, if present.
OLD_AGENT="$HOME/Library/LaunchAgents/local.spotify-lyrics-overlay.plist"
if [ -f "$OLD_AGENT" ]; then
    echo "==> Removing old SpotifyLyricsOverlay install"
    launchctl unload "$OLD_AGENT" 2>/dev/null || true
    rm -f "$OLD_AGENT"
    rm -rf "$HOME/Applications/SpotifyLyricsOverlay.app"
    rm -rf "$HOME/Library/Caches/spotify-lyrics-overlay"
fi

echo "==> Building (release)"
cd "$REPO"
swift build -c release

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$REPO/.build/release/LyricPill" "$APP_DIR/Contents/MacOS/LyricPill"
cp "$REPO/app/Info.plist" "$APP_DIR/Contents/Info.plist"
# Ad-hoc signature gives the app a stable identity, so the one-time
# "control Spotify" Automation grant survives rebuilds.
codesign --force --sign - "$APP_DIR"

echo "==> Installing LaunchAgent (starts at login)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP_DIR/Contents/MacOS/LyricPill</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST
launchctl unload "$AGENT_PLIST" 2>/dev/null || true
launchctl load "$AGENT_PLIST"

echo
echo "Done. Look for the ♫ icon in the menu bar."
echo "First playback will ask for permission to control Spotify — click Allow."
