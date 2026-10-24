# Changelog

All notable changes to LyricPill. The format follows [Keep a Changelog](https://keepachangelog.com/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Project website at https://theranjithjayaram.github.io/lyric-pill/ (static, no dependencies),
  deployed from `site/` by GitHub Pages.
- Debug flags `--snapshot-settings out.png [tab]` and `--snapshot-pill out.png` render the app's own
  interface to PNGs (the website's pictures).

### Changed
- `install.sh` builds only the Mac's own architecture (the DMG stays universal) and no longer
  migrates pre-1.0 source installs.
- Translation planning is skipped for already-translated replays, and a queued translation whose
  track has already changed is dropped before the model runs.
- Translation orchestration is one pure, tested module. A song whose translation came back
  incomplete (a language pack not yet downloaded, a transient failure) is shown as far as it got
  but no longer cached that way — downloading the pack later now takes effect on the next play.

### Fixed
- Opening Settings → Translation crashed the app (the translator's host window was created off the
  main thread). Not in 1.0.0; introduced and fixed between releases.
- Settings → Translation: the *Translate from* switches now line up in one column.
- `--simulate` with an unreadable file exits 1 (was 0); a debug flag given without its value is
  reported instead of silently ignored.

## [1.0.0] — 2026-10-23

First public release.

### Added
- Downloadable `.dmg` built by GitHub Actions on every `v*` tag, with SHA-256 checksum. Universal
  binary (Apple silicon + Intel). Signed and notarized when the maintainer's Developer ID secrets
  are configured; otherwise ad-hoc signed with documented *Open Anyway* instructions.
- **Settings window** (menu ♫ → Settings…, ⌘,): overlay mode, launch at login, Spotify automation
  status, pill font size and opacity, reset position.
- **Translation settings**: choose the target language and any number of source languages among
  those Apple's on-device Translation framework supports (macOS 15+); see each language pack's
  install status and download it from the app. Lyrics in Devanagari, Arabic, Cyrillic, Han, Kana,
  Hangul, Thai and Latin scripts are routed by a deterministic script table; ambiguous scripts
  (e.g. Russian vs Ukrainian) are disambiguated on-device with Apple's language recognizer.
- **Launch at login** via `SMAppService` (shows up in System Settings → Login Items).
- **Check for Updates…** (About tab) — on demand only; compares with the latest GitHub release.
- App icon; hardened-runtime entitlements; `install.sh` / `uninstall.sh` for source installs.
- `SECURITY.md`, `PRIVACY.md`, `CONTRIBUTING.md`, release process documentation.

### Changed
- Translation never shows macOS's language-pack download sheet on its own any more; packs are
  downloaded from Settings → Translation, and the menu status row says when one is missing.
- The LaunchAgent plist used by earlier source installs is removed by `install.sh`; the app now
  manages its own login item.
- lrclib `User-Agent` carries the real app version.

### Fixed
- A translation requested while another was still running was silently dropped (e.g. when
  skipping quickly between songs); requests are now queued.

[Unreleased]: https://github.com/theranjithjayaram/lyric-pill/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/theranjithjayaram/lyric-pill/releases/tag/v1.0.0
