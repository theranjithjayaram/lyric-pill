# LyricPill

Show the current **time-synced lyric line** as a draggable, click-through pill on your screen
while Spotify plays — for any track that has synced lyrics on [lrclib.net](https://lrclib.net).

One small native macOS menu-bar app: Swift + AppKit, **zero third-party dependencies**, built with
the standard toolchain (`swift build`). No Electron, no interpreter, no accounts, no API keys.

## Features

- Always-on-top, click-through lyric pill; drag it anywhere (Move Mode), position remembered.
- Menu-bar modes: **Auto** (show only while a synced line is playing), **On**, **Off**.
- **Optional Hindi → English translation** (macOS 15+): lyrics written in Devanagari script are
  translated **on-device** with Apple's Translation framework and prefixed with a monochrome `⇄`
  marker. Per line — mixed-script uploads keep non-Hindi lines as-is. Everything stays local.
- Honest status row in the menu: playing / no synced lyrics / lyrics server unreachable.

## How it works

```
Spotify ──"PlaybackStateChanged" notification──► LyricPill (menu-bar app)
   ▲                                                  │
   └── Apple events (track, position, play state) ◄───┤
                                                      │
                lrclib.net ──HTTPS──► synced LRC (disk-cached per song)
                                                      │
                 timing engine picks the active line  │
                                                      ▼
                    borderless click-through NSPanel (the pill)
```

- **Lyrics** come from lrclib.net (artist + title + album + duration): exact lookup, then a search
  fallback, then a last-resort search with annotation suffixes (`(From "Movie")`, `(feat. X)`)
  stripped — duration-gated so the wrong song can't match. Results (including misses) are cached
  under `~/Library/Caches/lyric-pill/`; misses expire after 24 h so new releases get re-checked;
  server outages are never cached and surface as "Lyrics server unreachable".
- **Timing**: playback position is interpolated with a monotonic clock and re-synced every 10 s
  while playing.

### Designed to be weightless

- **No periodic tick** — one timer is armed for exactly the next lyric-line boundary.
- **Fully idle when silent** — paused, Spotify closed, or mode Off ⇒ zero timers, zero polling;
  the process sleeps until Spotify's notification wakes it.
- Network only when a *new* song starts (cached forever after); translation is on-device.
- Measured: ~55 MB RAM, ~0.3 % CPU while playing, ~350 KB binary, a few KB of cache per song.

## Requirements

- macOS 13+ (translation feature needs macOS 15+).
- Xcode Command Line Tools with Swift 6+ (`xcode-select --install`).
- Spotify desktop client.

## Install

```bash
git clone https://github.com/theranjithjayaram/lyric-pill.git
cd lyric-pill
./install.sh
```

`install.sh` builds a release binary, assembles `~/Applications/LyricPill.app` (ad-hoc signed),
installs a LaunchAgent so it starts at login, and launches it now.

Play a song. The **first time**, macOS asks *"LyricPill would like to control Spotify"* —
click **Allow**. The first Hindi-script song asks once to download Apple's Hindi↔English language
pack (optional; Cancel just skips translation).

## Uninstall

```bash
./uninstall.sh
```

## Usage

Click the **♫ icon** in the menu bar: mode selection, Move Mode (drag the pill, toggle off to
save), the Hindi→English toggle, and a live status row.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Overlay never appears | Menu ♫ → status row. Auto mode + track without synced lyrics = hidden (expected). |
| Status mentions Apple events | System Settings → Privacy & Security → Automation → LyricPill → allow Spotify. |
| Every song shows nothing | Status says "Lyrics server unreachable"? lrclib.net is down — new tracks fetch fresh once it recovers. |
| Stale lyrics suspected | `rm -rf ~/Library/Caches/lyric-pill/` |

## Development

```bash
swift run lyrics-tests                        # unit tests (parser, timing, lrclib client)
swift run LyricPill --simulate examples/sample.lrc      # drive the overlay with no Spotify
swift run LyricPill --translate-check examples/hindi-sample.lrc
swift run LyricPill --engine-check examples/sample.lrc
```

Tests are a plain executable because Command Line Tools ship neither XCTest nor Swift Testing.
Architecture notes and the full decision log: [docs/design.md](docs/design.md).

## Privacy

To find lyrics, the app sends the playing track's **artist, title, album, and duration** to
lrclib.net over HTTPS — nothing else, ever. Translation runs entirely on-device. No analytics,
no accounts, no telemetry.

## Legal

- Not affiliated with, endorsed by, or sponsored by Spotify. It talks to the Spotify desktop
  client through Spotify's own public AppleScript interface.
- Lyrics are fetched at runtime from [lrclib.net](https://lrclib.net), a community lyrics service;
  no lyrics are bundled or redistributed by this project. Lyrics remain the property of their
  rights holders.
- Code: MIT — see [LICENSE](LICENSE).
