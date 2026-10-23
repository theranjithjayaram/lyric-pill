#!/usr/bin/env bash
# Package LyricPill.app into a compressed DMG with an Applications shortcut.
#
#   scripts/make-dmg.sh APP_PATH OUT_DMG [--sign IDENTITY]
#
# Writes OUT_DMG and OUT_DMG.sha256. First-party tools only: hdiutil, codesign, shasum.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: make-dmg.sh APP_PATH OUT_DMG [--sign IDENTITY]" >&2
    exit 2
fi
APP="$1"
OUT="$2"
shift 2
IDENTITY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) IDENTITY="$2"; shift 2 ;;
        *) echo "make-dmg.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -d "$APP" ] || { echo "make-dmg.sh: no app bundle at $APP" >&2; exit 1; }
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lyricpill-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging $(basename "$APP")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $OUT"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname LyricPill -srcfolder "$STAGE" -ov -format UDZO "$OUT"

if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    echo "==> Signing DMG with \"$IDENTITY\""
    codesign --force --timestamp --sign "$IDENTITY" "$OUT"
fi

(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")

echo "==> Wrote $OUT"
cat "$OUT.sha256"
