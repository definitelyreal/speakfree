<!-- ai:processed | session: 5b06900b-1498-4764-a786-48f408c36626 | date: 2026-06-10 -->
# speakfree — Release Runbook

This document covers the full path from source to a live Sparkle update.
It documents every secret *location* and *recovery procedure* — no secret
material appears here.

---

## Table of contents

1. [Prerequisites and tools](#1-prerequisites-and-tools)
2. [Keychain profiles and credentials](#2-keychain-profiles-and-credentials)
3. [Step-by-step release flow](#3-step-by-step-release-flow)
4. [Version-bump and appcast flow](#4-version-bump-and-appcast-flow)
5. [Recovering credentials from scratch](#5-recovering-credentials-from-scratch)
6. [Sparkle key rotation](#6-sparkle-key-rotation)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Prerequisites and tools

| Tool | Install | Purpose |
|------|---------|---------|
| Xcode (latest stable) | App Store | `xcrun`, `codesign`, `notarytool`, `stapler` |
| `create-dmg` | `brew install create-dmg` | Builds the distributable DMG |
| `gh` | `brew install gh` | Creates the draft GitHub release |
| Sparkle cask | `brew install --cask sparkle` | `sign_update` and `generate_keys` binaries |
| shellcheck | `brew install shellcheck` | Validates release scripts (CI gate) |

Sparkle is installed as a cask into `/opt/homebrew/Caskroom/sparkle/<version>/bin/`.
`build.sh` discovers the version dynamically (see §3).

---

## 2. Keychain profiles and credentials

Three credentials are required to build a signed, notarized, published release.
All live in the macOS login keychain on the release machine.

### 2a. Developer ID certificate — `Developer ID Application: Michael Morgenstern (AZ53Y7V4UZ)`

**What it is:** The code-signing certificate issued by Apple for distributing
outside the Mac App Store.

**Where it lives:** macOS login keychain. Verify with:

```
security find-certificate -c "Developer ID Application: Michael Morgenstern" -p
```

**What it signs:** every binary and framework inside `speakfree.app`, and the
app bundle itself.

**Recovery:** see §5a.

### 2b. Notarization profile — `speakfree-notary`

**What it is:** A `notarytool` keychain profile that stores the Apple ID
credentials (email + App Store Connect API key *or* app-specific password) used
to submit DMGs to Apple's notarization service.

**Where it lives:** macOS login keychain, under the profile name
`speakfree-notary`. Inspect with:

```
xcrun notarytool store-credentials --validate --keychain-profile speakfree-notary
```

**Recovery:** see §5b.

### 2c. Sparkle EdDSA signing key

**What it is:** An Ed25519 key pair. The private key signs each DMG during
`build.sh`; the public key is embedded in `Resources/Info.plist` as
`SUPublicEDKey` so Sparkle can verify updates on the user's machine.

**Where the private key lives:** macOS login keychain, stored by Sparkle's
`generate_keys` tool. The key label Sparkle uses is
`"Sparkle <public-key-base64>"`. Retrieve with:

```
/opt/homebrew/Caskroom/sparkle/$(ls /opt/homebrew/Caskroom/sparkle | head -1)/bin/sign_update --help
```

The private key is not exported to disk by default.

**Where the public key lives:** `Resources/Info.plist`, key `SUPublicEDKey`.
This value is committed to the repo and is not secret.

**Recovery / rotation:** see §5c and §6.

---

## 3. Step-by-step release flow

Everything from source to a live Sparkle update in one ordered list.

```
1.  Bump version in all three sources (see §4)
2.  Commit + push the version bump to main
3.  Run: bash scripts/build.sh
        └─ Calls check-version.sh (aborts on mismatch)
        └─ xcrun swift build -c release
        └─ Copies Info.plist + binary into speakfree.app
        └─ Verifies vendored dylib checksums (SHA256)
        └─ Bundles Sparkle.framework + whisper dylibs
        └─ Fixes rpaths
        └─ codesign (hardened runtime, entitlements)
        └─ create-dmg  →  speakfree-<VERSION>.dmg
        └─ xcrun notarytool submit  (--keychain-profile speakfree-notary)
        └─ xcrun stapler staple
        └─ sign_update  →  edSignature
        └─ Writes docs/appcast.xml  (LOCALLY — not pushed yet)
        └─ Updates docs/index.html download link (LOCALLY)
        └─ Installs to /Applications
        └─ gh release create (DRAFT)
4.  Dogfood the app from /Applications
5.  When satisfied, publish:
        bash scripts/publish-release.sh <VERSION>
        └─ Promotes draft GitHub release to public
        └─ git add docs/appcast.xml docs/index.html
        └─ git commit + git push origin main
        └─ Verifies the public download URL returns 200
```

### Sparkle bin discovery in build.sh

`build.sh` discovers the installed Sparkle cask version at runtime rather
than hardcoding a path.  See §4 for how this works.  If the Sparkle cask is
not installed the script exits with a clear error message before touching
any artifacts.

---

## 4. Version-bump and appcast flow

### Three sources that must agree

`scripts/check-version.sh` enforces agreement between these three sources at
build time and in CI:

| Source | Location | How to update |
|--------|----------|---------------|
| Swift constant | `Sources/OpenWisprLib/Version.swift` | Edit the `version` string literal |
| Info.plist | `Resources/Info.plist` | Edit `CFBundleShortVersionString` + `CFBundleVersion` |
| Appcast | `docs/appcast.xml` | Written automatically by `build.sh` — do not hand-edit |

### Version bump procedure

1. Edit `Sources/OpenWisprLib/Version.swift`: change the `version` string.
2. Edit `Resources/Info.plist`: update both `CFBundleShortVersionString` and
   `CFBundleVersion` to match.
3. `docs/appcast.xml` is rewritten by `build.sh` — do not pre-edit it.
4. Confirm: `bash scripts/check-version.sh` exits 0.
5. Commit: `git commit -m "build: bump version to X.Y.Z"`.

### Appcast update

`build.sh` fully rewrites `docs/appcast.xml` with the new version, download
URL, DMG byte length, EdDSA signature, and publish date.  It does NOT push
this file.  `publish-release.sh` commits and pushes it together with the
updated `docs/index.html` download button as a single atomic commit.

---

## 5. Recovering credentials from scratch

The instructions below assume the release machine's keychain was lost or you
are setting up a new machine.

### 5a. Developer ID certificate

1. Open **Xcode → Settings → Accounts** and add the Apple ID
   `michael@definitelyreal.com` (or the account associated with team
   `AZ53Y7V4UZ`).
2. Under Manage Certificates, click **+** → **Developer ID Application**.
   Xcode creates a new private key and requests a certificate from Apple.
3. Alternatively, revoke and re-issue from the
   [Apple Developer portal](https://developer.apple.com/account/resources/certificates/list)
   then import the `.cer` + the private key (if the key still exists in the
   original keychain, export it as `.p12` first).
4. Verify:
   ```
   security find-certificate -c "Developer ID Application: Michael Morgenstern"
   ```

### 5b. Notarization profile (`speakfree-notary`)

Apple recommends App Store Connect API keys for notarization (not app-specific
passwords) because they don't expire.

1. Visit [App Store Connect → Users and Access → Integrations → API](https://appstoreconnect.apple.com/access/api).
2. Create a key with the **Developer** role.  Download the `.p8` file
   (available only once).
3. Note the **Key ID** and **Issuer ID** shown on the same page.
4. Run:
   ```
   xcrun notarytool store-credentials "speakfree-notary" \
     --key /path/to/AuthKey_XXXX.p8 \
     --key-id XXXX \
     --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```
5. Validate:
   ```
   xcrun notarytool store-credentials --validate \
     --keychain-profile speakfree-notary
   ```

Alternatively, with an app-specific password:
```
xcrun notarytool store-credentials "speakfree-notary" \
  --apple-id "michael@definitelyreal.com" \
  --team-id AZ53Y7V4UZ \
  --password "xxxx-xxxx-xxxx-xxxx"
```

### 5c. Sparkle EdDSA key

If the private key was lost AND you do not have a backup, you must rotate the
key (see §6 — it requires a one-time forced update to push the new public key
to all existing users).

If you have the private key from a backup `.p12` or a keychain export:
1. Import it: `security import <backup.p12>` into the login keychain.
2. Verify `sign_update` can still sign:
   ```
   /opt/homebrew/Caskroom/sparkle/$(ls /opt/homebrew/Caskroom/sparkle | head -1)/bin/sign_update <any-dmg>
   ```
   It should print an `edSignature=` line.

---

## 6. Sparkle key rotation

Rotate only when the private key is lost or compromised.  Rotating breaks
auto-update for users on old public keys until they manually reinstall.

1. Generate a new key pair:
   ```
   /opt/homebrew/Caskroom/sparkle/$(ls /opt/homebrew/Caskroom/sparkle | head -1)/bin/generate_keys
   ```
   Output includes the new public key (base64).

2. Update `Resources/Info.plist`: replace the `SUPublicEDKey` value with the
   new public key.

3. Commit the `Info.plist` change to main.

4. For the first release after rotation, all users whose copy still has the
   old public key will need to manually download and install the DMG.  Add a
   prominent notice in the GitHub release notes.

5. After the rotation release ships, subsequent releases sign with the new key
   automatically.

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `FATAL: extracted Sparkle signature looks invalid` | `sign_update` failed or no private key in keychain | Run `sign_update <dmg>` manually; check keychain for the EdDSA private key |
| `notarytool submit` fails with "The credentials provided are not valid" | Profile stale or wrong team | Re-run `notarytool store-credentials` (§5b) |
| `codesign: no identity found` | Developer ID cert missing from keychain | Re-import certificate (§5a) |
| `FATAL: libwhisper still points to …` | `install_name_tool` failed | Check that `otool` is from the Xcode Command Line Tools, not a stale path |
| `build.sh: Sparkle cask not installed` | Sparkle cask removed or never installed | `brew install --cask sparkle` |
| Sparkle cask deprecated warning | Cask `sparkle` is flagged as deprecated in brew | The cask is only used for its `sign_update` binary; the deprecation does not affect the release binary. If the cask is removed, copy `sign_update`/`generate_keys` from a known-good version or download directly from the [Sparkle GitHub releases](https://github.com/sparkle-project/Sparkle/releases). |

---

_Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626_
