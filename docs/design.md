# Spotify Lyrics Overlay (macOS) — Design

**Status:** Working
**Reference:** `spotify-lyrics-overlay` (GNOME 42/Wayland original at
`~/Documents/groups-mac-data/projects/spotify-lyrics-overlay`)

## Goal

Same product as the Ubuntu original: show the current synced-lyrics line as an always-on-top,
click-through overlay while Spotify plays. Single active line, auto-shown when synced lyrics
exist, toggleable from the menu bar, draggable, position persisted.

## Why the architecture differs from the Ubuntu original

| Constraint | GNOME 42 / Wayland | macOS |
|---|---|---|
| Always-on-top overlay | Only possible inside `gnome-shell` → separate shell extension | Any app: borderless `NSPanel` at `.statusBar` level |
| Crash isolation | Extension code runs *in* the shell → logic pushed to a daemon | App is its own process; a crash takes down nothing |
| Track/playback events | MPRIS D-Bus | `com.spotify.client.PlaybackStateChanged` distributed notification + Apple events |
| IPC | D-Bus contract between daemon and extension | None needed — one process |

Result: the two-process daemon + extension design collapses into **one small AppKit app**.

## Decisions

| Topic | Decision |
|---|---|
| Language / UI | Swift + AppKit via SwiftPM — first-party only, zero third-party packages |
| Overlay | Borderless non-activating `NSPanel`, `ignoresMouseEvents`, `.canJoinAllSpaces` + `.fullScreenAuxiliary` |
| Spotify watching | Distributed notification wakes us; one compiled AppleScript reads state/position/track atomically |
| Lyrics source | lrclib.net (same as original), stdlib `URLSession`, disk cache in `~/Library/Caches` |
| Sync | Monotonic-clock interpolation between authoritative position samples; resync every 10 s while playing |
| Scheduling | **No periodic tick** — one-shot timer armed for the next line boundary; zero timers when idle |
| Position persistence | `UserDefaults` (center point of the pill) |
| Modes | Off / On / Auto + Move Mode, same semantics as the original |
| Tests | Pure-logic units (parser, engine, client) via a self-contained runner (`swift run lyrics-tests`) — CLT ships no XCTest/Swift Testing |
| Packaging | `install.sh` → ad-hoc-signed `~/Applications/SpotifyLyricsOverlay.app` + LaunchAgent (RunAtLoad) |

## Deviations from the reference implementation

- **Units**: engine works in ms (AppleScript gives seconds) instead of MPRIS µs.
- **Transient network failures are not cached** as misses — the client returns a distinct
  `.unavailable` outcome and the app retries with backoff (20 s doubling to 5 min) while the
  track plays. (The original cached them permanently.)
- **Cached misses expire after 24 h** so fresh releases get re-checked once lrclib catches up.
- **Cleaned-title last-resort search**: annotation suffixes (`(From "Movie")`, `(feat. X)`,
  remaster tags) are stripped and the artist filter dropped, gated to ±10 s duration.
- **`nextBoundaryMs()`** added to the timing engine so the app can sleep until exactly the
  next line change instead of ticking at 150 ms.
- **Overlay anchoring**: persisted point is the pill's *center*, so lines of different width
  stay centered where the user placed it (the original anchored top-left).

## Trust boundaries / privacy

Sends artist, title, album, duration to lrclib.net over HTTPS; nothing else leaves the machine.
Apple-events access to Spotify requires the user's one-time Automation consent
(`NSAppleEventsUsageDescription` is set; ad-hoc signing keeps the TCC grant stable across
rebuilds).

## Out of scope (YAGNI, same as original)

- Per-word / karaoke highlighting (lrclib is line-level).
- Players other than the Spotify desktop client.
- Editing / correcting lyrics.
