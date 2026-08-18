# Spotify Lyrics Overlay (macOS)

Show the current **time-synced lyric line** as a draggable, click-through overlay on your screen
while Spotify plays — for any track that has synced lyrics.

macOS port of `spotify-lyrics-overlay` (GNOME 42/Wayland). The Ubuntu
version needed a Python daemon + shell extension split because GNOME/Wayland can't draw arbitrary
always-on-top overlays; macOS can, so this is **one small native app** — Swift + AppKit, zero
third-party dependencies.

## How it works

```
Spotify ──"PlaybackStateChanged" distributed notification──► menu-bar app
   ▲                                                             │
   └────── Apple events (track, position, play state) ◄──────────┤
                                                                 │
                    lrclib.net ──HTTPS──► synced LRC (disk-cached)
                                                                 │
                     timing engine picks the active line         │
                                                                 ▼
                        borderless click-through NSPanel (the pill)
```

- **Track watching** — Spotify broadcasts a notification on every play/pause/track-change/seek;
  the app then reads the authoritative position over Apple events (the standard Spotify
  AppleScript interface).
- **Lyrics** — fetched from [lrclib.net](https://lrclib.net) (artist + title + album + duration),
  parsed from LRC, cached on disk under `~/Library/Caches/spotify-lyrics-overlay/`.
  Exact lookup, then a search fallback, then a last-resort search with annotation suffixes
  (`(From "Movie")`, `(feat. X)`, …) stripped — duration-gated so the wrong song can't match.
  Misses are cached for 24 h (new releases gain lyrics on lrclib over time). If lrclib is
  unreachable (network error or 5xx), nothing is cached and that song simply goes without
  lyrics — the menu status says so; the next track (or a replay) fetches fresh.
- **Timing** — playback position is interpolated with a monotonic clock between samples and
  re-synced every 10 s while playing.
- **Hindi translation (optional, macOS 15+)** — when fetched lyrics are written in Devanagari
  script, they're translated to English **on-device** via Apple's Translation framework (one-time
  system language-pack download; zero network per song, result cached to disk). Romanized Hindi,
  English uploads, and other languages are shown as-is. Toggle: menu → "Translate Hindi → English".

### Designed to be weightless

- Single native process, ~15 MB RAM, no Electron / web view / interpreter.
- **No periodic tick.** One timer is armed for exactly the next lyric-line boundary
  (the Ubuntu version woke 7×/sec; this wakes once per lyric line).
- **Fully idle when silent.** Paused, Spotify closed, or mode Off ⇒ zero timers, zero polling —
  the process sleeps until Spotify's notification wakes it.
- Timer tolerances let the kernel coalesce wakeups for battery.

## Requirements

- macOS 13+ (built and tested on macOS 26).
- Xcode Command Line Tools with Swift 6+ (`xcode-select --install`).
- Spotify desktop client.

## Install

```bash
cd ~/projects/spotify-lyrics-overlay-mac
./install.sh
```

`install.sh` builds a release binary, assembles `~/Applications/SpotifyLyricsOverlay.app`
(ad-hoc signed), installs a LaunchAgent so it starts at login, and launches it now.

Play a song. The **first time**, macOS asks *"Spotify Lyrics Overlay would like to control
Spotify"* — click **Allow**. The line appears bottom-center.

## Usage

Click the **♫ icon** in the menu bar:

- **Mode: Off / On / Auto** — `Auto` shows the overlay only while a synced line is playing;
  `Off` hides it; `On` shows whenever a line is available (frozen while paused).
- **Move Mode** — toggle on, drag the pill anywhere, toggle off. The position is remembered.
- **Translate Hindi → English** — on-device translation of Devanagari-script lyrics (see above).
- The first menu row shows live status (playing / no synced lyrics / permission problems).

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Overlay never appears | Menu-bar ♫ → status row. `Auto` mode + track without synced lyrics = hidden (expected). |
| Status says Apple events failed | System Settings → Privacy & Security → **Automation** → Spotify Lyrics Overlay → allow Spotify. |
| No menu-bar icon | `launchctl list \| grep spotify-lyrics` — rerun `./install.sh`. |
| One song shows nothing | That track has no synced lyrics on lrclib (cached for 24 h; overlay stays hidden). |
| Every song shows nothing | Menu status row says "Lyrics server unreachable"? lrclib.net is down — new tracks fetch fresh once it recovers. |
| Stale lyrics suspected | `rm -rf ~/Library/Caches/spotify-lyrics-overlay/` |

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/local.spotify-lyrics-overlay.plist
rm ~/Library/LaunchAgents/local.spotify-lyrics-overlay.plist
rm -rf ~/Applications/SpotifyLyricsOverlay.app ~/Library/Caches/spotify-lyrics-overlay
```

## Development

```bash
swift run lyrics-tests   # unit tests: LRC parser, timing engine, lrclib client
swift build              # debug build

# Drive the overlay from a local .lrc file with no Spotify (debug):
swift run SpotifyLyricsOverlay --simulate examples/sample.lrc
```

The tests are a plain executable rather than `swift test` because the Xcode Command Line Tools
ship neither XCTest nor Swift Testing (both require a full Xcode install).

The Spotify watcher, overlay panel, and menu bar are integration code, verified live rather than
unit-tested (same philosophy as the Ubuntu original).

## Privacy

To find lyrics, the app sends the playing track's **artist, title, album, and duration** to
lrclib.net over HTTPS. No account, credentials, or other data are sent. Results (including
misses) are cached under `~/Library/Caches/spotify-lyrics-overlay/`.

## Limitations

- Spotify desktop only (bundle id `com.spotify.client`).
- Line-level sync only (lrclib timing is per-line, so no per-word karaoke).
- Local files in Spotify work; podcasts/ads simply show nothing.

## License

MIT — see [LICENSE](LICENSE).
