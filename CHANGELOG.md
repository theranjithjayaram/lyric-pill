# Changelog

All notable changes to LyricPill. The format follows [Keep a Changelog](https://keepachangelog.com/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] — 2026-10-23

First public release.

### Added
- Downloadable `.dmg` built by GitHub Actions on every `v*` tag, with SHA-256 checksum. Signed and
  notarized when the maintainer's Developer ID secrets are configured; otherwise ad-hoc signed with
  documented *Open Anyway* instructions.
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
