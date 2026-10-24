# Security

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/theranjithjayaram/lyric-pill/security/advisories/new)
rather than a public issue. You should hear back within a week. There is no bug bounty; this is a
free, volunteer-maintained project.

## What the app does — and does not — do

LyricPill is a small native macOS app with **no third-party code**. Its complete surface:

| Capability | Detail |
| --- | --- |
| Network | HTTPS `GET` to `lrclib.net` when a *new* track starts (artist, title, album, duration). HTTPS `GET` to `api.github.com` **only** when you click *Check for Updates…*. Nothing else, ever. No background polling. |
| Local automation | Apple events to the Spotify desktop app (read current track and position). Guarded by macOS's Automation permission prompt; the app never sends events to any other application and never launches Spotify. |
| Files written | `~/Library/Caches/lyric-pill/` (lyrics + translations), `~/Library/Preferences/io.github.theranjithjayaram.lyric-pill.plist` (settings). Nothing else. |
| Translation | Apple's on-device Translation framework. Language packs are downloaded by macOS, not by the app, and only after you ask for one in Settings. |
| Privileges | Runs as your user. Does not request accessibility, screen recording, input monitoring, location, or any other privacy-sensitive permission. No helper tools, no launch daemons, no kernel extensions. |
| Updates | Never self-modifies. *Check for Updates…* only opens the GitHub release page in your browser. |

Full details: [PRIVACY.md](PRIVACY.md).

## Build integrity

- Every release is built by a public GitHub Actions workflow
  ([`.github/workflows/release.yml`](.github/workflows/release.yml)) from the tagged commit.
  Each release ships a `.sha256` next to the DMG; verify with `shasum -a 256 -c LyricPill-x.y.z.dmg.sha256`.
- When the maintainer's Developer ID certificate is configured, releases are signed with the
  hardened runtime and notarized by Apple; the release notes say which. Unsigned (ad-hoc) builds
  make macOS show its "unverified developer" warning — see the README for the one-time *Open
  Anyway* step. You can always build from source with `./install.sh`.
- The app is intentionally *not* sandboxed: controlling Spotify via Apple events is the whole
  point, and that needs the `com.apple.security.automation.apple-events` entitlement.

## Supported versions

Only the latest release receives fixes.
