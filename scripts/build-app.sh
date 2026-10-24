#!/usr/bin/env bash
# Build LyricPill.app from the SwiftPM release product.
#
#   scripts/build-app.sh [--version X.Y.Z] [--build N] [--sign IDENTITY] [--out DIR] [--archs "A B"]
#
#   --version  CFBundleShortVersionString   (default: contents of VERSION)
#   --build    CFBundleVersion              (default: git commit count, or 1)
#   --sign     codesign identity            (default: "-" = ad-hoc)
#   --out      output directory             (default: build, relative to the cwd)
#   --archs    CPU architectures            (default: "arm64 x86_64" = universal)
#
# Works from any cwd. First-party tools only: swift, lipo, plutil, strip, codesign.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Info.plist is the one place the bundle id is defined.
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$REPO/app/Info.plist")"

VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
BUILD_NUMBER=""
IDENTITY="-"
OUT="build"
ARCHS="arm64 x86_64"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD_NUMBER="$2"; shift 2 ;;
        --sign) IDENTITY="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --archs) ARCHS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "build-app.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 1)"
fi
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
APP="$OUT/LyricPill.app"

# Universal binary (CI runners are Apple silicon; the README promises Intel):
# one build per architecture, then lipo. `swift build --arch a --arch b` would
# need xcbuild, which Command Line Tools installs lack.
SLICES=()
for arch in $ARCHS; do
    echo "==> swift build -c release --triple $arch-apple-macosx --product LyricPill"
    (cd "$REPO" && swift build -c release --triple "$arch-apple-macosx" --product LyricPill)
    BIN_DIR="$(cd "$REPO" && swift build -c release --triple "$arch-apple-macosx" --product LyricPill --show-bin-path)"
    SLICES+=("$BIN_DIR/LyricPill")
done

echo "==> Assembling $APP (version $VERSION, build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/LyricPill"
cp "$REPO/app/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$REPO/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
strip -x "$APP/Contents/MacOS/LyricPill"

if [ "$IDENTITY" = "-" ]; then
    # Ad-hoc: a stable identifier so the one-time "control Spotify" Automation
    # grant survives rebuilds.
    echo "==> Signing (ad-hoc)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    echo "==> Signing with \"$IDENTITY\" (hardened runtime)"
    codesign --force --options runtime --timestamp \
        --entitlements "$REPO/app/LyricPill.entitlements" \
        --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "==> Built $APP ($(lipo -archs "$APP/Contents/MacOS/LyricPill"))"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signature|Timestamp)=' || true
