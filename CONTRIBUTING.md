# Contributing

Thanks for your interest. LyricPill is deliberately small; the easiest way to help is a precise
bug report with the menu-bar status text and the macOS/Spotify versions.

## Ground rules (these are design invariants, not preferences)

1. **Zero third-party dependencies.** Swift, AppKit/SwiftUI and Apple's frameworks only. A PR that
   adds a package dependency will be declined.
2. **Event-driven, never polling.** No periodic timers while idle, no background network. One
   one-shot timer for the next lyric line while playing, one slow resync timer — that is all.
3. **No retry loops or background machinery.** If a service is down the status row says so.
4. **Deterministic.** Rule-based decisions; cached results are frozen so a song never changes its
   lyrics between plays.
5. **Simple beats clever.** When in doubt, remove machinery.
6. **No real song lyrics in the repository** — tests and examples use invented text.

See [docs/CONTEXT.md](docs/CONTEXT.md) for the full decision log before proposing a change.

## Building

```bash
git clone https://github.com/theranjithjayaram/lyric-pill.git
cd lyric-pill
swift build                  # needs Xcode Command Line Tools, Swift 6+
swift run lyrics-tests       # unit tests (pure-logic module)
swift run LyricPill --simulate examples/sample.lrc --settings   # overlay + settings, no Spotify
./install.sh                 # release build → /Applications/LyricPill.app
```

Tests are a plain executable because Command Line Tools ship neither XCTest nor Swift Testing.
Add a test function to `Tests/LyricsCoreTests/` and register it in `main.swift`.

## Pull requests

- Keep the PR focused; explain the user-visible behaviour change in one paragraph.
- Run `swift build` with `set -o pipefail` (a piped `tail` hides failures) and `swift run lyrics-tests`.
- Match the surrounding comment density and naming. The app target is main-thread-by-convention —
  do not add `@MainActor` to its classes (see CONTEXT.md §7.7).
- Add a line to [CHANGELOG.md](CHANGELOG.md) under *Unreleased*.
- By contributing you agree your work is released under the [MIT License](LICENSE).

## Releasing (maintainer)

See [docs/release-process.md](docs/release-process.md).
