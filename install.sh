#!/usr/bin/env bash
# Build LyricPill from source and install it (/Applications, or ~/Applications
# when /Applications is not writable). Prefer the DMG from GitHub Releases
# unless you want to build it yourself.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="io.github.theranjithjayaram.lyric-pill"
APP_NAME="LyricPill.app"
PROCESS_PATTERN='LyricPill.app/Contents/MacOS/LyricPill'

echo "==> Building $APP_NAME"
"$REPO/scripts/build-app.sh" --out "$REPO/build"
BUILT="$REPO/build/$APP_NAME"

if pgrep -f "$PROCESS_PATTERN" >/dev/null; then
    echo "==> Quitting the running LyricPill"
    pkill -f "$PROCESS_PATTERN" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$PROCESS_PATTERN" >/dev/null || break
        sleep 0.5
    done
fi

# Earlier installs started the app from a LaunchAgent. The app now manages
# "Launch at login" itself (Settings) via SMAppService, so remove those.
for label in "$BUNDLE_ID" local.spotify-lyrics-overlay; do
    plist="$HOME/Library/LaunchAgents/$label.plist"
    [ -f "$plist" ] || continue
    echo "==> Removing legacy LaunchAgent $label"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
done
# Pre-release install name.
rm -rf "$HOME/Applications/SpotifyLyricsOverlay.app" "$HOME/Library/Caches/spotify-lyrics-overlay"

if [ -w /Applications ]; then
    DEST_DIR=/Applications
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
for old in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; do
    [ -e "$old" ] || continue
    rm -rf "$old" || echo "warning: could not remove $old" >&2
done

echo "==> Installing $DEST_DIR/$APP_NAME"
# cp -R keeps the bundle byte-identical, so the signature made by build-app.sh
# stays valid — do not re-sign after copying.
cp -R "$BUILT" "$DEST_DIR/$APP_NAME"
open "$DEST_DIR/$APP_NAME"

echo
echo "Done. Look for the ♫ icon in the menu bar."
echo "  • First playback asks for permission to control Spotify — click Allow."
echo "  • Hindi → English translation (macOS 15+): Settings → Translation downloads the language pack."
