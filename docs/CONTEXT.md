# LyricPill — Full Project Context & Decision Log

Handoff document for future sessions. Self-contained: assumes zero prior context.
State as of 2026-10-23.

## 1. What this is

**LyricPill** — a native macOS menu-bar app that shows the current time-synced lyric line of the
playing Spotify track as an always-on-top, click-through, draggable "pill" overlay. Optional
on-device Hindi→English translation. Swift + AppKit, zero third-party dependencies.

- Repo: https://github.com/theranjithjayaram/lyric-pill (**private**; flip with
  `gh repo edit --visibility public`). Owner account `theranjithjayaram` (personal).
  The Mac's active `gh` account is the work one — run `gh auth switch -u theranjithjayaram`
  before pushing, switch back after.
- Local checkout: `~/projects/lyric-pill` (default branch `main`).
- Installed at `~/Applications/LyricPill.app`, started at login by LaunchAgent
  `~/Library/LaunchAgents/io.github.theranjithjayaram.lyric-pill.plist`.
- History: ported from the author's own `spotify-lyrics-overlay` (GNOME 42/Wayland, Python daemon +
  shell extension, MIT) which lives at `~/Documents/groups-mac-data/projects/spotify-lyrics-overlay`.
  On macOS the two-process design collapsed into one app because macOS allows arbitrary
  always-on-top overlay windows; GNOME/Wayland does not.

## 2. Hard requirements the owner imposed (treat as invariants)

1. **Lightweight**: no Electron/web view/interpreter; minimal RAM/CPU/battery/storage.
2. **No polling, no frequent network calls**: event-driven; zero timers when idle.
3. **No retry loops / cron / background machinery**: if the lyrics server is down, that song simply
   has no lyrics — but the menu status must say *"Lyrics server unreachable"*, never a false
   "no synced lyrics". (A retry-with-backoff system was built, then **removed on request**.)
4. **Deterministic**: every choice rule-based; chosen lyrics/translations frozen by cache.
5. **Mainstream, first-party tools only**: Swift, AppKit, SwiftPM, Apple Translation framework.
   No niche/out-of-date deps. (Also a durable owner preference: documented/standard behaviour only.)
6. **Simple > clever**: when offered "smart" options (language-preference ranking, retry loops),
   the owner chose the simpler behavior.

## 3. Architecture

```
Spotify ──"com.spotify.client.PlaybackStateChanged" distributed notification──► LyricPill
   ▲                                                                               │
   └────────── Apple events (one compiled AppleScript: state/position/track) ◄─────┤
                                                                                   │
                      lrclib.net ──HTTPS──► synced LRC ──► disk cache per song     │
                                                                                   │
                      TimingEngine picks the active line (monotonic interpolation) │
                                                                                   ▼
                                     borderless click-through NSPanel (the pill)
```

### Targets (SwiftPM, `Package.swift`, swift-tools 6.0, language mode v5, macOS 13+)

- **LyricsCore** (library, pure logic, fully unit-tested):
  - `LrcParser.swift` — LRC → `[LrcLine(ms, text)]`; multi-timestamp lines; 1–3 digit fractions;
    **splits on `\.isNewline`** (see bug #3); stable sort via index tiebreak; `serialize()` inverse.
  - `TimingEngine.swift` — injectable clock; `seek(toMs:)`, `setPlaying`, `positionMs()`
    (interpolates while playing, frozen while paused), `currentIndex()` (binary search, greatest
    start ≤ pos), `nextBoundaryMs()` (enables tickless scheduling).
  - `LrclibClient.swift` — fetch chain + cache (see §4); `LyricsOutcome` enum
    `.found(String) / .none / .unavailable`; `cleanTitle()`; `cacheDigest()` (SHA-1 helper);
    ephemeral URLSession (no CFNetwork disk cache), 15 s timeout, UA
    `lyric-pill/1.0 (https://github.com/theranjithjayaram/lyric-pill)`.
  - `ScriptDetector.swift` — `isMostlyDevanagari` (≥30% of alphabetic scalars in U+0900–097F),
    `isMostlyLatin` (≥70% < U+0250) — the translation gates.
- **LyricPill** (executable, AppKit, main-thread-by-convention — **no `@MainActor`**, see bug #7):
  - `main.swift` — single-instance guard (bundle id); flags `--simulate <lrc>`,
    `--translate-check <lrc>`, `--engine-check <lrc>`; `.accessory` activation.
  - `AppController.swift` — wiring + scheduling + render + translation orchestration.
  - `SpotifyWatcher.swift` — distributed notification observer; NSWorkspace launch/terminate
    observers for `com.spotify.client`; `refresh()` runs one compiled NSAppleScript returning
    `{stateFlag, pos, id, name, artist, album, duration}` as raw descriptors (never text — locale
    decimal separators); never sends Apple events when Spotify isn't running (would launch it).
  - `OverlayWindow.swift` — borderless `.nonactivatingPanel`, level `.statusBar`,
    `.canJoinAllSpaces + .fullScreenAuxiliary`, `ignoresMouseEvents`; pill = layer-backed view,
    black 0.55 alpha, radius 12; font SF 20pt semibold (was 24, reduced on request); label sized by
    **`cell.cellSize(forBounds:)`** (see bug #4); anchored on persisted *center* point; Move Mode =
    `isMovableByWindowBackground` + didMove observer.
  - `StatusItemController.swift` — ♫ menu: status row (via `menuWillOpen`), Mode Off/On/Auto,
    Move Mode, Translate Hindi→English toggle, Quit.
  - `LyricsTranslator.swift` — Apple Translation framework host (see §5) + `TranslateCheck` debug
    runner.
  - `Settings.swift` — UserDefaults: `mode` (off/on/auto, default auto), `center-x/y`,
    `translate-hindi` (default true).
- **lyrics-tests** (executable at `Tests/LyricsCoreTests/`): hand-rolled runner
  (`swift run lyrics-tests`), **because Command Line Tools ship neither XCTest nor Swift Testing**
  (both need full Xcode; this Mac has CLT only). 72 tests, all passing. All fixture text is
  invented — **no real song lyrics anywhere in the repo** (advisor-mandated; see §8).

### Scheduling / battery model (the core "weightless" design)

- **No periodic render tick.** One one-shot timer armed for exactly `nextBoundaryMs()`
  (+20 ms lead, 50 ms tolerance); re-armed on fire. Ubuntu original ticked at 150 ms — this was a
  deliberate improvement.
- **Resync timer**: 10 s repeating, 1 s tolerance, **only while playing** — one local Apple event
  to correct interpolation drift. Not network.
- Paused / Spotify quit / mode Off ⇒ both timers torn down; app fully idle until a notification.
- Spotify **relaunch** can auto-resume without posting the notification → two one-shot reads at
  +3 s/+12 s after NSWorkspace `didLaunchApplicationNotification` for Spotify (bug #8).
- Fetches run on a utility queue; results hop to main; `trackGen` generation counter discards
  stale fetches; `watcher.refresh()` re-syncs position after lyrics arrive.
- Measured (playing, translation active): ~56 MB RSS, ~0.3% CPU, 342 KB binary, 1.4 MB cache.

## 4. Lyrics pipeline (lrclib.net) — selection policy & caching

Query key: `artist|title|album|durationS` (SHA-1 → `~/Library/Caches/lyric-pill/<hex>.lrc`).

Fetch chain (first hit wins; **not popularity — lrclib's API has no popularity data**):
1. `GET /api/get` exact (artist+title+album+duration).
2. `GET /api/search` track+artist → among results *with* syncedLyrics, closest duration
   (first-in-response wins ties).
3. Last resort: `GET /api/search` with **cleaned title, no artist filter**, duration-gated ±10 s.
   `cleanTitle` strips trailing `(...)`/`[...]` groups containing from/feat/ft/with/remaster
   (word-bounded; `(Live)` deliberately kept — different timing) and `" - From ..."` dash suffixes.
   This fallback exists because Spotify credits (e.g. composer "Pritam"/"Rochak Kohli") often
   mismatch lrclib's artist ("Arijit Singh"), and film songs carry `(From "Movie")` suffixes.

Outcome → cache mapping (**status-code mapping is load-bearing — bug #6**):
- `.found` → cached forever (deterministic replay).
- `.none` (definitive miss: 404 or empty results through the whole chain) → cached as an **empty
  file with a 24 h TTL** (mtime-based) so new releases get re-checked once lrclib catches up.
- `.unavailable` (network error, timeout, malformed JSON, **any non-200/404 incl. 429/5xx**) →
  **never cached**, no fallback requests after an abort; menu shows "Lyrics server unreachable";
  no retry until the next track change / replay (owner's explicit choice).

Known data realities (explained to owner, accepted):
- lrclib is community-sourced: entries may be romanized, native script, or **English translations**
  (e.g. *Tera Yaar Hoon Main* — 17 of 18 synced entries were English).
- **Bilingual uploads** duplicate each timestamp (original line then translation). Parser preserves
  file order on equal ms; the engine's bisect lands on the **last** equal entry ⇒ effectively shows
  the second (conventionally the translation). Positional, not language-aware.
- **Dubbed film songs share durations** ⇒ when the only synced entry is another language's dub
  (e.g. Telugu lyrics while the Tamil *Vishwaroopam* plays), it shows. No reliable fix without
  knowing the heard language (Spotify metadata lacks it); owner accepted "some lyrics > none".

## 5. Translation (optional, macOS 15+, on-device)

- Trigger: `Settings.translateHindi` on **and** a lyric line is individually
  `isMostlyDevanagari` (**per-line gate** — mixed Hindi/Punjabi uploads must not send Gurmukhi
  lines to the model; bug #5). Only those lines are sent.
- Engine: Apple Translation framework, hi→en, batch
  (`session.translations(from:)`), **`prepareTranslation()` must be called first** (silently hangs
  /fails otherwise — bug #7). The framework only exposes sessions through SwiftUI's
  `.translationTask`, so a hidden 320×80 host window (alpha 0.01, screen corner) carries one;
  it becomes visible+centered only when the one-time language-pack download consent is needed
  (`LanguageAvailability.status == .supported`). Model runs in a macOS system process — zero RSS
  cost to the app; zero network.
- Output validation: each translated line must be `isMostlyLatin`, else the original line is kept
  (the hi model emits mangled output for scripts it can't read).
- Accepted lines are displayed prefixed **"⇄ "** (monochrome marker, owner-requested, display-only)
  and the merged display lines are cached at key `…|hi-en-v2` (v2 bumped to abandon pre-validation
  poison). Translation happens once per song ever; cache replays are instant.
- The Hindi↔English language pack is installed on this Mac (user consented ~2026-08).
- Languages: **only hi→en shipped.** Tamil is NOT supported by Apple's on-device translation, and
  romanized lyrics can't be translated by anything (not recognizable script). This was researched
  and told to the owner when they asked for translation options.

## 6. UX contract

- Modes: **Auto** = show only while playing *and* synced lyrics exist and line non-empty;
  **On** = show whenever a line is available (frozen while paused); **Off** = hidden
  (also disarms the line timer).
- Move Mode: pill becomes draggable; center persisted; render suppressed during drag; placeholder
  "♫ drag me ♫" when empty. Position clamped to the screen containing the saved center, falling
  back to main (unplugged-monitor safety). Default: bottom-center, 120 pt up.
- Pill auto-sizes per line (center-anchored), caps at 80% screen width then tail-truncates.
- Menu status row (computed on open, no background refresh):
  Simulating / Spotify is not running / Spotify: <AppleScript error> / Nothing playing /
  Fetching lyrics… / **Lyrics server unreachable** / No synced lyrics for this track /
  Showing synced lyrics / Paused.
- Sleep/lid: process frozen by OS. Screensaver/lock draw at level ~1000 > our 25 ⇒ overlay hidden.
  Clamshell+external display works normally.

## 7. Bug log (every root cause found; the costly lessons)

1. **AppleScript `st` is reserved** (ordinal suffix, `1st`) → `set st to 0` fails to compile;
   NSAppleScript compiles lazily so it only surfaced at runtime as menu error
   "Expected expression but found st". Renamed to `stateFlag`. *Lesson: compile-check AppleScript
   standalone (`osacompile`) before embedding.*
2. **Pill truncation on every line**: sized via `NSAttributedString.size()` which under-reports the
   cell's need by ~1–4 px (even `intrinsicContentSize` does, under truncating line-break modes);
   any shortfall ⇒ `byTruncatingTail` ellipsis. Fix: measure with `cell.cellSize(forBounds:)` + 1px.
3. **Frozen single line all song**: lrclib files with **CRLF** endings — in Swift `"\r\n"` is ONE
   grapheme, so `split(separator: "\n")` doesn't split at all ⇒ whole file = one line ⇒ every
   timestamp got the text after the *last* timestamp. Python's `splitlines()` (the original) was
   immune. Fix: `split(whereSeparator: \.isNewline)` + trim `.whitespacesAndNewlines`.
4. **"No synced lyrics" during outages**: any non-200 was treated as a definitive miss **and
   cached**. During lrclib outages Cloudflare answers fast 5xx ⇒ 6 poisoned 24 h misses in one
   morning. Fix: only 404 = miss; everything else = `.unavailable`, never cached, no fallback
   requests. lrclib also intermittently returns **429** (seen 2026-10-15) — same handling.
5. **Mixed-script uploads**: a 76%-Devanagari song dragged its Gurmukhi (Punjabi) lines into the
   hi→en model, which emitted mojibake that got cached & ⇄-marked. Fix: per-line gate + per-line
   Latin-output validation + cache key bump.
6. **lrclib slowness**: connects alone took 7.5 s during a degradation → raised request timeout
   10→15 s. Outage detection: your own probe first (`curl -m 15` a known-good query), and compare
   against `example.com` to split app-vs-service.
7. **Translation framework traps**: (a) without `prepareTranslation()` first, the task closure never
   produced results; (b) marking the translator `@MainActor` hard-errors at every nonisolated call
   site **even in Swift 5 language mode** (own-module isolation is enforced; Apple-API MainActor
   calls are tolerated) — the app is main-thread-by-convention instead; (c) a debug runner must
   retain the translator for the app lifetime or the window/model deallocates mid-flight.
8. **Lyrics dead after Spotify restart**: auto-resume can skip `PlaybackStateChanged`; the app
   (event-driven, no timers while "player gone") waited forever. Fix: NSWorkspace launch observer →
   one-shot refreshes at +3 s/+12 s.
9. **Verification traps on this machine** (cost real time, remember these):
   - `swift build | tail -1` **masks failures** (pipeline exit = tail's). Two separate incidents ran
     a stale binary. Use `set -o pipefail` or grep `error:` separately.
   - `swift run lyrics-tests` builds only that product's closure — the app binary can stay stale.
     `swift build` builds everything.
   - `pgrep -x SpotifyLyricsOverlay` intermittently failed (name truncation); `pgrep -f` is robust.
   - CGWindowList sees windows of this shell's child processes but not the LaunchAgent instance's
     (macOS 26 privacy); verify overlay rendering via a child-process run. `screencapture` needs
     Screen Recording permission (absent). Overlay window: layer 25 = `.statusBar` ✓.
   - Moving the repo directory invalidates `.build` (module cache paths) → move `.build` aside and
     rebuild. The sandbox may deny `rm -rf` outside the session dirs — `mv` aside to
     `$CLAUDE_JOB_DIR/tmp` works.
   - lsof: `-p PID -i` ORs the selectors (needs `-a` to AND) — unfiltered output misled once.
   - Unified log: `log show --predicate 'process == "translationd"'` to see translation activity;
     none = the task never fired.
10. **Menu-bar settings "duplicates"**: macOS remembers every past menu-bar extra per identity;
    debug runs of the raw binary create ghost rows in System Settings. Harmless, prune on reboot.

## 8. Publication / legal (advisor-reviewed 2026-10-12, verdict applied)

- MIT (c) 2026 Ranjith Jayaram. Zero third-party deps. All code original (port of author's own
  MIT project).
- **No real lyrics in the repo** — an advisor review caught 4 real Bollywood lines in
  `examples/hindi-sample.lrc` + fragments in tests contradicting the README's "no lyrics bundled"
  claim; all replaced with invented Devanagari/Gurmukhi/romanized text (which the translator still
  handles — verified end-to-end: "मैं तुम्हारा दोस्त हूँ" → "I am your friend").
- **"Spotify" removed from the app/repo name** (Spotify brand guidelines prohibit it in names);
  nominative use + non-affiliation disclaimer in README §Legal. Talks to Spotify only via its own
  public AppleScript interface; no credentials, no scraping.
- lrclib: free/no-auth API; identifying User-Agent set as they request; lyrics fetched at runtime,
  never redistributed; rights stay with owners (stated in README).
- Privacy: only artist/title/album/duration leave the machine (to lrclib over HTTPS); translation
  on-device; no telemetry.

## 9. Install / operate

- `./install.sh`: swift release build → assemble `~/Applications/LyricPill.app` → **ad-hoc codesign**
  (stable identity so the TCC Automation grant survives rebuilds) → LaunchAgent (RunAtLoad, no
  KeepAlive so Quit works) → load. Also migrates away the pre-release
  `SpotifyLyricsOverlay`/`local.spotify-lyrics-overlay` install. `./uninstall.sh` reverses all of it.
- First playback after a bundle-id change triggers the one-time
  "LyricPill would like to control Spotify" TCC prompt (`NSAppleEventsUsageDescription` set).
  `tccutil reset AppleEvents <bundle-id>` only works while the bundle resolves.
- Defaults domain: `io.github.theranjithjayaram.lyric-pill`.
- Debug: `--simulate f.lrc` (drives overlay, no Spotify), `--engine-check f.lrc` (parse+selection at
  fixed positions, prints), `--translate-check f.lrc` (detect+translate, prints).

## 10. Considered and NOT done (with reasons) — the roadmap quarry

- **Retry with backoff on fetch failure** — built (20 s→5 min caps, playing-gated), then removed:
  owner wanted zero loop machinery. A **single** delayed retry (~30 s, one shot) was offered
  2026-10-15 when lrclib 429s made single-shot fetches blank whole songs; owner hasn't taken it.
- **Language-preference candidate ranking** (prefer native-script/original entries via
  NLLanguageRecognizer when multiple synced versions exist) — offered, owner chose positional
  simplicity ("best match, fine").
- **Skip wrong-language dub lyrics** (match script against album-name language hints) — offered,
  recommended against (some lyrics > none), declined.
- **Second lyrics provider fallback** — floated during the lrclib outage, deliberately not built.
- **Per-word karaoke** — impossible with lrclib (line-level timing only).
- **Other players** (Apple Music etc.) — never requested; the watcher is Spotify-specific
  (notification name + bundle id + AppleScript vocabulary) but the seam is clean: everything behind
  `SpotifyWatcher.Snapshot`.
- **Generic translation pairs** (configurable source/target + per-script gates) — the hi→en pair
  and Devanagari gate are constants in `LyricsTranslator`/`AppController`; a bigger app would lift
  them into a table of (language, script-range, model-pair).
- **Popularity-based selection** — impossible; lrclib exposes no vote data.
- **MediaRemote private framework** for playback state (no TCC prompt) — rejected: private API,
  violates the "documented/standard only" rule.
- **XCTest/Swift Testing** — unavailable on CLT; revisit if full Xcode ever installed.
- **App icon, Sparkle updates, notarized DMG, Homebrew tap** — never discussed; natural next steps
  for public distribution (ad-hoc signing means other users must build from source — that's why
  install is clone + `./install.sh`).

## 11. Where a "bigger app" session should start

- Read §2 invariants first — they are owner preferences, not technical limits.
- The clean seams: `LyricsCore` is UI-free and fully tested; `SpotifyWatcher.Snapshot` isolates the
  player; `LyricsOutcome` isolates the provider; `OverlayWindow` isolates rendering;
  `LyricsTranslator` isolates translation. Multi-player / multi-provider / multi-language all have
  obvious extension points.
- Keep the measurement habits from §7.9 — they caught every regression here.
- Owner's taste, demonstrated repeatedly: diagnose with live evidence before changing code; honest
  status over silent failure; delete machinery rather than add it; verify end-to-end on the real
  Mac (the app runs on the machine the sessions run on).
