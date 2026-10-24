# Privacy

LyricPill has no accounts, no analytics, no telemetry, no crash reporting, and no third-party
SDKs. This page lists every piece of data that leaves your Mac and everything the app stores.

## Data that leaves your Mac

| When | Where | What | Why |
| --- | --- | --- | --- |
| A new track starts playing in Spotify (first time only — results are cached) | `lrclib.net` over HTTPS | Artist, title, album, duration of the track; a `User-Agent` header naming this app and its version | To find time-synced lyrics. lrclib.net is a community lyrics service with its own [privacy practices](https://lrclib.net). |
| You click **Check for Updates…** | `api.github.com` over HTTPS | A request for the latest release of this repository (no identifying data beyond your IP address and the standard HTTP headers) | To compare your version with the newest release. Never happens automatically. |

Nothing else is ever sent. In particular: no listening history is uploaded, no lyrics are uploaded,
and translation never leaves the device.

## Data stored on your Mac

| Location | Content | Remove with |
| --- | --- | --- |
| `~/Library/Caches/lyric-pill/` | Fetched lyrics and on-device translations, one small file per track (so a song is fetched once and replays instantly) | `rm -rf ~/Library/Caches/lyric-pill` or `./uninstall.sh` |
| `~/Library/Preferences/io.github.theranjithjayaram.lyric-pill.plist` | Your settings: overlay mode, pill position and style, translation languages | `defaults delete io.github.theranjithjayaram.lyric-pill` |
| macOS language packs (managed by Apple, shared with other apps) | Translation models you chose to download | System Settings → General → Language & Region → Translation Languages |

## Permissions

- **Automation (Spotify)** — macOS asks once whether LyricPill may control Spotify. It is used
  only to read the current track and playback position. Revoke in System Settings → Privacy &
  Security → Automation.
- **Login item** — only if you turn on *Launch at login* in Settings. Visible and removable in
  System Settings → General → Login Items.

The app requests no other permissions.

## Children, cookies, tracking

None of these apply: the app stores no cookies, sets no identifiers, and does not profile users.

## Changes

This document is versioned with the code. Any change to what the app sends or stores will be
listed in [CHANGELOG.md](CHANGELOG.md).
