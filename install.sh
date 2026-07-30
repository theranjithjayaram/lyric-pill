#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/SpotifyLyricsOverlay.app"
AGENT_LABEL="local.spotify-lyrics-overlay"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

echo "==> Building (release)"
cd "$REPO"
swift build -c release

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$REPO/.build/release/SpotifyLyricsOverlay" "$APP_DIR/Contents/MacOS/SpotifyLyricsOverlay"
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
		<string>$APP_DIR/Contents/MacOS/SpotifyLyricsOverlay</string>
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
