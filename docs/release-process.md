# Release process

Releases are produced by [`.github/workflows/release.yml`](../.github/workflows/release.yml) on
a GitHub-hosted macOS runner. Nothing is built on a developer's machine.

## 1. Cut a release

```bash
# on main, clean tree
echo 1.1.0 > VERSION                      # bump; the workflow refuses a tag that disagrees
$EDITOR CHANGELOG.md                       # move Unreleased → ## [1.1.0] — YYYY-MM-DD
git commit -am "Release 1.1.0"
git tag v1.1.0
git push origin main v1.1.0                # the tag push triggers the Release workflow
```

The workflow: builds (`swift build -c release`), runs the unit tests, assembles `LyricPill.app`,
signs it, packs `LyricPill-1.1.0.dmg`, notarizes it when possible, and creates the GitHub Release
with the DMG, its `.sha256`, and the CHANGELOG section as notes.

## 2. Signing & notarization (optional, recommended)

Without secrets the workflow produces an **ad-hoc signed** DMG. It works, but macOS Gatekeeper
shows *"Apple could not verify LyricPill is free of malware"* on first open and the user must
allow it in System Settings → Privacy & Security (documented in the README). To ship a build that
opens cleanly, add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Your **Developer ID Application** certificate + private key exported from Keychain Access as `.p12`, base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `APPLE_ID` | The Apple ID of the developer account |
| `APPLE_TEAM_ID` | 10-character Team ID (developer.apple.com → Membership) |
| `APPLE_APP_PASSWORD` | An [app-specific password](https://support.apple.com/102654) for that Apple ID |

Requirements: a paid Apple Developer Program membership (US$99/year). With the first three
secrets the app is signed with the hardened runtime and `app/LyricPill.entitlements`; with all
five it is also submitted to Apple's notary service and the ticket is stapled to the DMG. The
release notes say which path was taken.

## 3. Verify a published release

```bash
curl -LO https://github.com/theranjithjayaram/lyric-pill/releases/download/v1.1.0/LyricPill-1.1.0.dmg
curl -LO https://github.com/theranjithjayaram/lyric-pill/releases/download/v1.1.0/LyricPill-1.1.0.dmg.sha256
shasum -a 256 -c LyricPill-1.1.0.dmg.sha256
spctl --assess --type open --context context:primary-signature -v LyricPill-1.1.0.dmg   # notarized builds only
```

## 4. Local dry run

```bash
scripts/build-app.sh                                  # build/LyricPill.app, ad-hoc signed
scripts/make-dmg.sh build/LyricPill.app build/LyricPill-dev.dmg
open build/LyricPill-dev.dmg
```

`scripts/make-icon.swift` regenerates `app/AppIcon.icns` if the icon design changes.

## 5. First-time repository setup checklist

- [ ] Repository visibility: public (`gh repo edit --visibility public --accept-visibility-change-consequences`).
- [ ] Settings → Actions → General: Actions allowed to run. The release job requests
      `contents: write` itself, so the default *Read repository contents* token permission is
      fine unless an organisation policy forbids workflows from elevating.
- [ ] Settings → Code security → *Private vulnerability reporting*: enabled (SECURITY.md links to it).
- [ ] Optional: the five signing secrets above.
- [ ] Optional: a Homebrew cask (`brew install --cask`) can be added once releases are notarized —
      casks for unsigned apps get poor reviews and `--no-quarantine` workarounds.
