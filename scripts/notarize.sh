#!/usr/bin/env bash
# Notarize a signed DMG with Apple, staple the ticket, and verify it.
#
#   APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… scripts/notarize.sh OUT_DMG
#
# APPLE_APP_PASSWORD is an app-specific password (appleid.apple.com). Needs
# notarytool/stapler from Xcode; the release workflow runs this on CI.
set -euo pipefail

DMG="${1:?usage: notarize.sh DMG}"
[ -f "$DMG" ] || { echo "notarize.sh: no file at $DMG" >&2; exit 1; }
for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [ -z "${!name:-}" ]; then
        echo "notarize.sh: $name is not set" >&2
        exit 1
    fi
done

echo "==> Submitting $(basename "$DMG") for notarization"
LOG="$(mktemp "${TMPDIR:-/tmp}/notarize.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
    --wait 2>&1 | tee "$LOG"
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

echo "==> Stapling"
xcrun stapler staple "$DMG"

echo "==> Verifying"
spctl --assess --type open --context context:primary-signature -v "$DMG"
