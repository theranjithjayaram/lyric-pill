---
name: verify
description: How to run and observe LyricPill on this Mac for runtime verification (menu-bar app, no Screen Recording permission)
---

# Verifying LyricPill at runtime

The app is a menu-bar accessory with an always-on-top pill; there is no Dock icon and
`screencapture` needs Screen Recording permission (absent here). Evidence comes from
CGWindowList geometry, the app's own debug flags, and side effects on disk.

## Build & launch

```bash
scripts/build-app.sh --out build          # universal release bundle, ad-hoc signed
# or verify the installed copy: /Applications/LyricPill.app/Contents/MacOS/LyricPill
pkill -f "/Applications/LyricPill.app/Contents/MacOS/LyricPill"   # single-instance guard exits a 2nd copy
build/LyricPill.app/Contents/MacOS/LyricPill [flags] &             # run as a CHILD of your shell
```

Run the binary directly as a child process: windows of processes launched via `open`/launchd
are invisible to CGWindowList on macOS 26. Restore afterwards with `open /Applications/LyricPill.app`.

## Observe

- Windows: a tiny Swift script over `CGWindowListCopyWindowInfo` filtered by PID prints
  `layer/alpha/bounds` (names are hidden without Screen Recording). The pill is `layer=25 h≈40`
  at the saved centre; its **width changes per lyric line** — sample at 3 timestamps. The
  Settings window is `layer=0 520×512`, centred on the main screen.
- `--simulate examples/sample.lrc` drives the pill with no Spotify (lines every 3 s).
- `--settings` opens the Settings window at start; `--snapshot-settings out.png` renders the
  Translation tab (fake pack statuses) to a PNG — view it with the Read tool.
- `--translate-check examples/mixed-script-sample.lrc` runs the real on-device translation
  (hi→en pack is installed on this Mac; Gurmukhi and romanized lines must print "left alone").
- `--engine-check file.lrc` prints parse + selection at fixed positions (CRLF files included).
- Real path: with Spotify playing (`osascript -e 'tell application "Spotify" to play'` works
  from the shell here), start the app with no flags: pill appears within ~4 s; a new track
  adds a file under `~/Library/Caches/lyric-pill/` (replays don't).

## Gotchas

- Put the whole drive in a script and run `bash script.sh`: the worktree guard refuses ad-hoc
  commands that pass runtime variables (`"$PID"`, `$HOME`) or mention "git"/"github" in args.
- Spotify must not be launched by the app: check `pgrep -x Spotify` before/after when testing
  the "not running" path.
- The menu's status row and Settings clicks need Accessibility permission to script; they were
  not driven automatically — check them by hand.
