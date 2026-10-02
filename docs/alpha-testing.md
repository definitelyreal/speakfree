<!-- ai-suggestion:unverified | session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b | date:2026-10-01 | asof:2026-10-01 -->
# Try the speakfree alpha

The alpha previews unified dictation and clipboard History, an Edit window, and
updated settings. It requires an Apple Silicon Mac running macOS 14 or later.
Alpha builds may have bugs; use them deliberately and keep the stable installer.

## Install

1. Open [Releases](https://github.com/definitelyreal/speakfree/releases). Choose
   **v1.8.0-alpha.1**, marked **Pre-release**, and download
   **speakfree-1.8.0-alpha.1.dmg** from its assets. The **Source code** downloads
   are for developers. If no alpha DMG is attached, the installable alpha is not
   available yet.
2. If you already use speakfree, download the
   [stable installer](https://github.com/definitelyreal/speakfree/releases/tag/v1.7.2)
   and back up your existing settings before installing. In Finder, choose
   **Go → Home**, press **Command-Shift-.** to show hidden folders, open **.config**,
   and copy the **speakfree** folder to a safe backup location. This may include
   recordings and downloaded models, so allow enough space. A new user has no
   existing folder to back up.
3. Finish any dictation or Edit session and quit speakfree. Move the existing
   **speakfree.app** from **Applications** to Trash before copying the alpha app
   from the disk image into **Applications**. Do not merge app bundles or run two
   copies together.
4. Open speakfree. Its menu title should include **Alpha 1.8.0-alpha.1 Testing**.
   Follow the microphone and Accessibility prompts if macOS requests them.

The alpha uses the same settings and app identity as stable speakfree. Separate
simultaneously running alpha/stable installations are not supported.

## Try it

- Dictate a short sentence into an ordinary text field. Press **Command-Shift-V**
  to open History and paste that dictation again. If another app owns the shortcut,
  choose a different shortcut in settings or change the other app's shortcut.
- Clipboard capture is optional. Turn it on in **Clipboard** settings to include
  copied items alongside dictations. Saving history across restarts is a separate
  choice; review its retention controls before enabling it.
- Try the Edit window using made-up text. Optional Claude cleanup sends the
  selected text to Claude when invoked; ordinary local dictation and History do
  not require it.

Send feedback with the exact alpha version, macOS version, destination app, and
steps that reproduce the problem. Use invented text. Review any diagnostic files
before sharing them; public issues must not contain private recordings, clipboard
contents, credentials, or personal transcripts.

## Updates and returning to stable

This alpha has **manual updates only**. It has no Sparkle update feed; installing
it does not enroll you in automatic alpha releases. Download a newer alpha or a
stable version explicitly from Releases.

The development branch is [alpha/clipboard-history](https://github.com/definitelyreal/speakfree/tree/alpha/clipboard-history).
Pushing that branch updates source code, not an installed app or an existing
release download. Bookmark [Releases](https://github.com/definitelyreal/speakfree/releases)
for future alpha installers; each published version gets its own release link.

To return to stable, finish dictation/editing, quit speakfree, move the alpha app
to Trash, and install the saved stable DMG. The stable app does not provide the new
History or Edit features. Reinstalling an app does not restore earlier data or
preferences. If you need an exact settings rollback, keep a separate copy of the
current alpha settings folder, then restore the pre-alpha backup while speakfree
is quit. Retain both copies: the pre-alpha backup will not contain recordings or
changes made during alpha testing. Automatic downgrade/migration of alpha history
is not provided.

## Packaging an alpha

Use a clean, tested source commit whose version is **X.Y.Z-alpha.N**. The build
script's explicit **--alpha** mode uses the normal Developer ID signing, vendored
libraries, hardened runtime, notarization, and stapling flow. It stamps the full
source commit, retains a build receipt and SHA-256 checksum, and removes the
automatic-update feed from the packaged app. The tracked stable website, feed,
and bundle template remain unchanged.

The package is still local when the script finishes. Publication is separate:
push a reviewed source snapshot without private development history, create the
exact source tag, and attach the checked DMG/checksum to a GitHub **Pre-release**
that is **not Latest**. A branch or GitHub prerelease flag alone does not isolate
an updater. No stable update-feed promotion belongs in this alpha flow.
