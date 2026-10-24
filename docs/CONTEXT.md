# LyricPill — Full Project Context & Decision Log

Handoff document for future sessions. Self-contained: assumes zero prior context.
State as of 2026-10-23.

## 1. What this is

**LyricPill** — a native macOS menu-bar app that shows the current time-synced lyric line of the
playing Spotify track as an always-on-top, click-through, draggable "pill" overlay. Optional
on-device translation (any pair Apple's Translation framework supports; Hindi→English by
default). Swift + AppKit, zero third-party dependencies.

- Repo: https://github.com/theranjithjayaram/lyric-pill (**private** until the owner flips it with
  `gh repo edit --visibility public --accept-visibility-change-consequences`). Owner account
  `theranjithjayaram` (personal). The Mac's active `gh` account is the work one — run
  `gh auth switch -u theranjithjayaram` before pushing, switch back after.
- Local checkout: `~/projects/lyric-pill` (default branch `main`).
- Distribution (since 1.0.0, see §12): DMG built by GitHub Actions on `v*` tags; `VERSION` file
  is the single source of truth; `scripts/build-app.sh` + `scripts/make-dmg.sh` reproduce it
  locally. Users install from the DMG or `./install.sh`.
- Installed at `/Applications/LyricPill.app` (or `~/Applications` when `/Applications` isn't
  writable); launch-at-login is the app's own `SMAppService` login item (Settings → General).
  The pre-1.0 LaunchAgent plist `io.github.theranjithjayaram.lyric-pill` is removed by
  `install.sh`.
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
    `.found(String) / .none / .unavailable` (the fetch chain returns the same enum — no private
    mirror); `cleanTitle()` (static regexes); `cacheKey(artist:title:album:durationS:)` +
    `cachePath(for:)` (SHA-1 → `<hex>.lrc`) are the client's public cache layout, which
    lyric-derived caches (translations) reuse with a suffix; transport = `defaultHttpGet(userAgent:)`
    (ephemeral URLSession, 15 s timeout) — the UA string is composed by the app (`AppInfo.userAgent`
    = `lyric-pill/<CFBundleShortVersionString> (https://github.com/theranjithjayaram/lyric-pill)`,
    `dev` when unbundled), so LyricsCore knows nothing about the repo.
  - `ScriptDetector.swift` — `dominantScript()` → `Script` enum (latin/greek/cyrillic/hebrew/
    arabic/devanagari/bengali/gurmukhi/tamil/thai/hangul/kana/han/other) by block-range table
    (Latin includes U+1E00–1EFF for Vietnamese); plurality wins; any kana letter ⇒ `.kana`
    (Japanese vs Chinese decided by rule, not model). The hi-only-era threshold predicates
    (`isMostlyDevanagari` ≥30 %, `isMostlyLatin` ≥70 %) were deleted in the 2026-10-24 simplify
    pass — nothing in production used them once `LanguageGate` shipped.
  - `TranslationCatalog.swift` — the 20 languages Apple's Translation framework offers (macOS 15)
    with their script; `normalize()` maps Apple ids (`zh-Hans-CN`, `en_US`) to catalog ids.
  - `LanguageGate.swift` — `plan(lines:enabledSources:target:recognizer:)` → `[TranslationBatch]`
    (per-line, rule-based: script → unique enabled language ⇒ translate; shared script ⇒ ask the
    recognizer, skip unless it names a candidate; same script as target ⇒ recognizer with the
    target as sink); `isPlausibleOutput` (target script check); `cacheKeySuffix` (`tr-<target>-
    <sorted effective sources>-v3`).
  - `AppleLanguageRecognizer.swift` — `NLLanguageRecognizer` **unconstrained**, top hypothesis
    accepted only if ≥0.5 *and* among the candidates (see bug #12).
  - `SemanticVersion.swift` — `Comparable`, parses `v1.2.3`/`1.2`/`1.2.3-beta`; used by the
    update check.
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
    Move Mode, Translate Lyrics toggle, Settings… (⌘,), About, Quit. Mode/translate write the
    shared `SettingsStore`; checkmarks re-read on every open.
  - `LyricsTranslator.swift` — Apple Translation framework host (see §5): FIFO job queue keyed by
    job identity (`current: Job?`; 60 s one-shot deadline per translate job, none for downloads —
    bug #14). **Owns the pack rule**: `translate(lines:from:to:skipIf:)` answers a
    `TranslateOutcome` (`translated / packNotDownloaded / unsupported / failed / skipped`) and a
    not-downloaded pack never reaches `prepareTranslation()`; `skipIf` lets the controller drop a
    job whose track already changed before the model runs. `availability(from:to:) → PackStatus`
    (the framework enum never leaves this file), `downloadLanguagePack(from:to:)` (the only path
    that shows the consent sheet), `supportedLanguageIDs`; + `TranslateCheck` runner.
  - `Settings.swift` — `SettingsStore: ObservableObject` (`.shared`), `@Published` + UserDefaults:
    `mode` (auto), `center-x/y`, `translate-enabled` (true; migrated once from `translate-hindi`),
    `translate-sources` (`["hi"]`), `translate-target` (`"en"`), `pill-font-size` (20, 14…36),
    `pill-opacity` (0.55, 0.2…1), `first-run-done`.
  - `SettingsWindow.swift` — `SettingsWindowController` (one 520×460 non-resizable window, built
    on first open, hidden on close) hosting SwiftUI `TabView`: General / Translation / About.
    Services reach the view as a struct of closures so the translator stays type-erased on
    macOS 13.
  - `LoginItem.swift` — `SMAppService.mainApp` register/unregister/status.
  - `SpotifyAutomation.swift` — TCC Automation status via `AEDeterminePermissionToAutomateTarget`
    (**by PID, on a background queue** — bug #11), no prompt, never launches Spotify.
  - `UpdateChecker.swift` — on-demand GET of the latest GitHub release + `AppInfo` (bundle
    version strings). Never automatic.
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

- Configuration: `translate-enabled`, `translate-target` (default `en`), `translate-sources`
  (default `["hi"]`) — any of the 20 catalog languages. Settings → Translation shows per-pair
  pack status (Installed / Download… / Unavailable) and is the **only** place a pack download
  (macOS's consent sheet) is started. A song change never pops the sheet: a pair whose pack is
  `.supported`-but-not-installed is skipped and the menu status row says
  "Showing lyrics — Hindi pack not downloaded (Settings → Translation)".
- Per-line gate = `LanguageGate.plan` (§3): script-table first, Apple's language recognizer only
  for scripts shared by several enabled languages, and "leave the line alone" on any doubt.
  Mixed Hindi/Punjabi uploads still never send Gurmukhi to the hi model (bug #5); romanized
  lines are never planned unless a Latin-script source is enabled, and even then only when the
  recognizer's *unconstrained* top guess is that language (bug #12).
- Engine: Apple Translation framework, batch (`session.translations(from:)`),
  **`prepareTranslation()` must be called first** (silently hangs/fails otherwise — bug #7).
  The framework only exposes sessions through SwiftUI's `.translationTask`, so a hidden 320×80
  host window (alpha 0.01, screen corner) carries one; it becomes visible+centered only for a
  Settings-driven pack download. Model runs in a macOS system process — zero RSS cost to the
  app; zero network. Jobs are queued FIFO, one in flight (a second request used to be dropped).
- Output validation: `LanguageGate.isPlausibleOutput` — the line must come back in the target's
  script, else the original line is kept (models emit mangled output for scripts they can't read).
- Accepted lines are displayed prefixed **"⇄ "** (monochrome marker, owner-requested). The marker
  is baked into the cached display lines at key `…|tr-<target>-<sources>-v3` (so changing the glyph
  means a key bump; v1/v2 entries are orphaned, not deleted). The cache is consulted *before* the
  language gate runs, so a replay never pays for planning. Translation happens once per song per
  configuration; replays are instant.
- The Hindi↔English language pack is installed on this Mac (user consented ~2026-08).
- Apple's catalog has no Tamil/Punjabi/Bengali; romanized lyrics can't be translated by anything
  on-device. Told to the owner when they asked for translation options; README says so too.

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
  Showing synced lyrics / Paused / "Showing lyrics — <Language> pack not downloaded (Settings →
  Translation)".
- Settings window (menu → Settings…/About, `--settings` flag; opens itself once on first run):
  General (mode, launch at login, Spotify automation status + pane shortcut, pill font size &
  opacity, reset position), Translation (see §5), About (version, Check for Updates…, links).
  Everything reads on appear or on click — no timers.
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
   - The debug binary really lives at `.build/arm64-apple-macosx/debug/LyricPill`
     (`.build/debug` is a symlink) — `pkill -f .build/debug/LyricPill` misses it; use
     `pkill -f "debug/LyricPill"`.
   - CGWindowList on macOS 26 reports window frames minus insets and hides window names without
     Screen Recording permission — print frames from inside the app when verifying placement.
   - The first `--translate-check` of a session once returned nil although the pack was
     installed; every later run worked. Cause unknown (cold `translationd`?); the task's catch
     now logs `translation failed: <error>` to stderr so the next occurrence is diagnosable.
10. **Menu-bar settings "duplicates"**: macOS remembers every past menu-bar extra per identity;
    debug runs of the raw binary create ghost rows in System Settings. Harmless, prune on reboot.
11. **`AEDeterminePermissionToAutomateTarget` hangs with a bundle-id descriptor** on macOS 26
    (blocks forever on an internal semaphore, even off the main thread). The PID descriptor of
    the running Spotify answers in ~50 ms; the URL form gives paramErr. So the probe targets by
    PID, runs on a background queue, and answers "Spotify is not running" before any AE call.
12. **Constrained `NLLanguageRecognizer` forces a pick**: with `languageConstraints = [id, en]`
    romanized Hindi came back "Indonesian" at ≥0.5 (probabilities are renormalised over the
    constraints). Fix: recognise unconstrained and accept the top guess only if it is one of the
    candidates — text that matches no candidate lands elsewhere and is skipped.
13. **`NSHostingController` sizing**: with default `sizingOptions` the Settings window was 0×0
    at `center()` time (landed with its left edge on mid-screen) and grew later. Fix:
    `sizingOptions = []` + explicit `setContentSize`.
14. **Translator queue could wedge forever** (review finding, not observed): `busy` was cleared
    only by the hosted task's completion, so a task that never fires/answers (cold
    `translationd`, host window never "appears") would block every later translation *and*
    Settings pack download for the process lifetime. Fix: per-job generation + one one-shot 60 s
    deadline for translate jobs (`complete(gen)` runs once; late/duplicate answers are ignored).
    Download jobs wait on the user's consent sheet and have no deadline.
15. **Universal build needs the right flags**: `swift build --arch arm64 --arch x86_64` requires
    xcbuild (full Xcode) and fails on Command Line Tools; one `swift build --triple
    <arch>-apple-macosx` per arch + `lipo -create` works everywhere. Found by the review: the
    first CI DMG would have been arm64-only while the README promised Intel.
16. **Checksum before staple**: `stapler staple` rewrites the DMG, so a `.sha256` computed by
    `make-dmg.sh` fails for notarized releases. The workflow computes it as its last file-touching
    step (one writer; `make-dmg.sh`'s sidecar serves CI artifacts and local dry runs). The app is
    notarized+stapled before packing so the copy users drag out opens offline.

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
  on-device; no telemetry. `Check for Updates…` hits api.github.com only on click. Written up for
  users in `PRIVACY.md` and `SECURITY.md` (private vulnerability reporting link).
- Signing: releases are Developer-ID-signed (hardened runtime, entitlement
  `com.apple.security.automation.apple-events`, no sandbox) and notarized **only when the five
  repo secrets exist** (`docs/release-process.md`); otherwise ad-hoc + "not notarized" in the
  notes and Gatekeeper "Open Anyway" instructions in the README. The owner has no Apple
  Developer membership as of 2026-10-23.
- Spotify brand: still nominative use only; the icon is an original ♫-in-a-pill, no Spotify
  marks.

## 9. Install / operate

- `scripts/build-app.sh [--version --build --sign --out --archs]`: `swift build -c release
  --triple <arch>-apple-macosx` per arch + `lipo -create` (universal by default) → assemble
  `build/LyricPill.app` (Info.plist versions via `plutil`, `AppIcon.icns`, `PkgInfo`, `strip -x`)
  → codesign (**ad-hoc with `--identifier <bundle id>`** so the TCC Automation grant survives
  rebuilds, or Developer ID with hardened runtime + entitlements) → `codesign --verify --strict`.
  `scripts/make-dmg.sh APP OUT [--sign]`: `hdiutil` UDZO with an `Applications` symlink +
  `.sha256`. `scripts/notarize.sh` (CI only), `scripts/release-notes.sh` (CHANGELOG section),
  `scripts/make-icon.swift` (regenerates `app/AppIcon.icns` — committed, build doesn't need it).
- `./install.sh`: build-app.sh for this Mac's architecture only (`--archs "$(uname -m)"` —
  a local install never needs the other slice) → quit running app → `cp -R` (no re-sign) to
  `/Applications` or `~/Applications` → `open`. `./uninstall.sh` reverses it (login item entry
  must be removed in System Settings if it was enabled). The pre-1.0 migration shims (LaunchAgent
  labels, `SpotifyLyricsOverlay`, `translate-hindi` default) were removed on 2026-10-24: the only
  machine that ever had them is the owner's, and it had already migrated.
- First playback after a bundle-id change triggers the one-time
  "LyricPill would like to control Spotify" TCC prompt (`NSAppleEventsUsageDescription` set).
  `tccutil reset AppleEvents <bundle-id>` only works while the bundle resolves.
- Defaults domain: `io.github.theranjithjayaram.lyric-pill`.
- Debug: `--simulate f.lrc` (drives overlay, no Spotify), `--engine-check f.lrc` (parse+selection at
  fixed positions, prints), `--translate-check f.lrc` (plans with all catalog languages enabled,
  target en; prints batches/results), `--settings` (opens the Settings window at start),
  `--snapshot-settings out.png` (renders the Translation tab with fake pack statuses to a PNG
  and exits — the way to check layout here, since `screencapture` needs Screen Recording).
- CI: `.github/workflows/ci.yml` (push to main / PRs: build, tests, ad-hoc app + DMG artifact);
  `release.yml` (tag `v*` = `v$(cat VERSION)`: build, sign, notarize if secrets, GitHub Release
  with DMG + sha256 + CHANGELOG notes). Runner `macos-15` has full Xcode.

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
- **Generic translation pairs** — DONE in 1.0.0 (`TranslationCatalog` + `LanguageGate`, §5).
- **Popularity-based selection** — impossible; lrclib exposes no vote data.
- **MediaRemote private framework** for playback state (no TCC prompt) — rejected: private API,
  violates the "documented/standard only" rule.
- **XCTest/Swift Testing** — unavailable on CLT; revisit if full Xcode ever installed.
- **App icon, DMG, CI release** — DONE in 1.0.0 (§12). **Sparkle** — rejected (third-party
  framework; invariant 5); on-demand GitHub check instead. **Homebrew cask** — deferred until
  releases are notarized (casks for unsigned apps need `--no-quarantine` workarounds).
  **Notarization** — wired up but dormant until the owner buys an Apple Developer membership and
  adds the secrets.
- **Register the login item automatically on first run** — not done: a downloaded app silently
  adding itself to Login Items is presumptuous; the first-run Settings window makes the toggle
  discoverable instead. (The owner's own install loses RunAtLoad on migration until they flip it.)

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

## 12. 1.0.0 public-distribution session (2026-10-23)

Owner's brief: "a complete, self-sufficient macOS app people download as a DMG; its own settings
incl. which translation models to download, multiple languages; security/licensing/bug-free;
free, open source OK." Done autonomously (away-mode) on branch `worktree-public-distribution`:

- Code: `SettingsStore` + Settings window, login item, Spotify automation probe, on-demand update
  check, translation generalised (catalog + gate + recognizer), translator job queue, pill style.
  Tests 72 → 185 (hand-rolled runner, all invented fixtures).
- Packaging: icon, entitlements, `scripts/*`, CI + Release workflows, rewritten
  `install.sh`/`uninstall.sh`, `VERSION`.
- Docs: README (user-facing), CHANGELOG, CONTRIBUTING, SECURITY, PRIVACY,
  `docs/release-process.md`, issue templates.
- Judgement calls recorded in away-mode notes: SMAppService replaces the LaunchAgent (default
  off); no Sparkle; translation never pops the pack-download sheet on its own; MIT stays.
- Shipped 2026-10-24: PR #1 squash-merged, repo public, `v1.0.0` released (ad-hoc DMG, verified
  end-to-end from the Releases page). PR #2 = Translate-from switch alignment.
- `/simplify` + `/verify` pass (2026-10-24, four review angles, applied): `LrclibClient` owns the
  cache layout and returns `LyricsOutcome` throughout; translator owns the pack rule and answers
  `TranslateOutcome` (one availability query per batch, stale jobs skipped before the model runs);
  `AppController` state is one `LyricsState` enum + `engine.isPlaying` + `store.mode` (no
  mirrors); dead `isMostly*` gate removed; debug flags parsed by one helper with real exit codes;
  Settings no longer builds the translator eagerly; scripts derive the bundle id from Info.plist,
  drop the pre-1.0 shims, and `install.sh` builds the native arch only. Runtime verification
  recipe: `.claude/skills/verify/SKILL.md`.
