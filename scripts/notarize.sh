#!/usr/bin/env bash
# Notarize a signed .app or .dmg with Apple, staple the ticket, and verify it.
#
#   APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… scripts/notarize.sh PATH
#
# PATH is LyricPill.app (submitted as a zip, stapled in place — run this before
# make-dmg.sh so the app inside the DMG carries its own ticket and opens
# offline) or the finished .dmg. Stapling changes the file: compute any
# checksum after this step. APPLE_APP_PASSWORD is an app-specific password
# (appleid.apple.com). Needs notarytool/stapler from Xcode; the release
# workflow runs this on CI.
set -euo pipefail

TARGET="${1:?usage: notarize.sh PATH}"
[ -e "$TARGET" ] || { echo "notarize.sh: nothing at $TARGET" >&2; exit 1; }
for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [ -z "${!name:-}" ]; then
        echo "notarize.sh: $name is not set" >&2
        exit 1
    fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/submit.log"

case "$TARGET" in
    *.app)
        # notarytool takes zip/dmg/pkg; ditto's zip keeps the bundle's metadata.
        SUBMIT="$WORK/$(basename "$TARGET" .app).zip"
        ditto -c -k --keepParent "$TARGET" "$SUBMIT"
        ;;
    *.dmg) SUBMIT="$TARGET" ;;
    *) echo "notarize.sh: expected a .app or .dmg, got $TARGET" >&2; exit 2 ;;
esac

echo "==> Submitting $(basename "$SUBMIT") for notarization"
xcrun notarytool submit "$SUBMIT" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
    --wait 2>&1 | tee "$LOG" || true
if ! grep -q 'status: Accepted' "$LOG"; then
    # Surface Apple's reasons before failing.
    ID="$(sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' "$LOG" | head -1)"
    if [ -n "$ID" ]; then
        xcrun notarytool log "$ID" \
            --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" || true
    fi
    echo "notarize.sh: notarization was not accepted" >&2
    exit 1
fi

echo "==> Stapling $(basename "$TARGET")"
xcrun stapler staple "$TARGET"

echo "==> Verifying"
case "$TARGET" in
    *.app)
        spctl --assess --type execute -v "$TARGET"
        ;;
    *.dmg)
        spctl --assess --type open --context context:primary-signature -v "$TARGET"
        ;;
esac
