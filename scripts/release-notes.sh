#!/usr/bin/env bash
# Print the CHANGELOG.md section for a version, for the GitHub Release body.
#
#   scripts/release-notes.sh VERSION
#
# Matches "## [VERSION]…", "## VERSION…" or "## vVERSION…" and prints everything
# up to the next "## " heading. Without CHANGELOG.md or a matching section it
# prints the one-line fallback "LyricPill VERSION".
set -euo pipefail

VERSION="${1:?usage: release-notes.sh VERSION}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$REPO/CHANGELOG.md"

notes=""
if [ -f "$CHANGELOG" ]; then
    notes="$(awk -v v="$VERSION" '
        /^## / {
            if (found) exit
            h = $0; sub(/^## +/, "", h)
            if (h ~ /^\[/) { h = substr(h, 2); i = index(h, "]"); if (i) h = substr(h, 1, i - 1) }
            else { sub(/[[:space:]].*$/, "", h) }
            if (h == v || h == "v" v) found = 1
            next
        }
        found && $0 !~ /^\[[^]]+\]: / { lines[n++] = $0 }   # skip link reference definitions
        END {
            start = 0; while (start < n && lines[start] ~ /^[[:space:]]*$/) start++
            end = n;   while (end > start && lines[end - 1] ~ /^[[:space:]]*$/) end--
            for (i = start; i < end; i++) print lines[i]
        }' "$CHANGELOG")"
fi

if [ -n "$notes" ]; then
    printf '%s\n' "$notes"
else
    echo "LyricPill $VERSION"
fi
