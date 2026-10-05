#!/usr/bin/env python3
# ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
"""Exercise the real packaging script with inert external signing/build tools.

Uses real git, PlistBuddy, hashes and filesystem operations in retained fixtures
under ignored build/. Never builds Swift, signs, uploads, installs or restarts an app.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "build" / "alpha-packaging-tests"
MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open("events.jsonl", "a") as f:
    f.write(json.dumps([name, *args]) + "\n")
if name == "xcrun" and args[:1] == ["swift"]:
    binary = pathlib.Path(".build/release/speakfree")
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text("#!/bin/sh\nexit 0\n")
    binary.chmod(0o755)
elif name == "xcrun" and args[:1] == ["notarytool"]:
    if os.environ.get("SF_TEST_FAIL_NOTARY") == "1":
        sys.exit(1)
elif name == "create-dmg":
    pathlib.Path(args[-2]).write_bytes(b"inert test DMG, not an application")
elif name == "otool":
    print("\t@rpath/libwhisper.1.dylib (compatibility version 1.0.0)")
'''


class AlphaPackagingTests(unittest.TestCase):
    def setUp(self):
        if sys.platform != "darwin":
            self.skipTest("Packaging uses macOS PlistBuddy")
        WORK.mkdir(parents=True, exist_ok=True)
        self.repo = Path(tempfile.mkdtemp(prefix="case-", dir=WORK))
        for relative in ("scripts/build.sh", "scripts/check-version.sh", "Resources/Info.plist",
                         "Resources/THIRD-PARTY-NOTICES.txt"):
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        info_path = self.repo / "Resources/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleShortVersionString"] = "1.7.2"
        info["CFBundleVersion"] = "1.7.2"
        info_path.write_bytes(plistlib.dumps(info))
        docs = self.repo / "docs"
        docs.mkdir()
        (docs / "appcast.xml").write_text(
            '<rss><channel><item>\n<sparkle:shortVersionString>1.7.2</sparkle:shortVersionString>\n'
            '<sparkle:version>1.7.2</sparkle:version>\n'
            '<enclosure url="https://example.invalid/speakfree-1.7.2.dmg"/>\n</item></channel></rss>\n')
        (docs / "index.html").write_text(
            '<a href="https://example.invalid/speakfree-1.7.2.dmg">Download</a>\n'
            '<span class="btn-sub">v1.7.2 </span>\n<h3>v1.7.2</h3>\n')
        version = self.repo / "Sources/SpeakFreeLib/Version.swift"
        version.parent.mkdir(parents=True)
        version.write_text('public let version = "1.8.0-alpha.1"\n')
        (self.repo / "Resources/AppIcon.icns").write_bytes(b"test icon")
        (self.repo / "scripts/speakfree.entitlements").write_bytes(plistlib.dumps({}))
        vendor = self.repo / "scripts/vendor/dylibs"
        vendor.mkdir(parents=True)
        checksums = []
        for name in ("libwhisper.1.8.3.dylib", "whisper-cli"):
            payload = b"inert vendored fixture"
            (vendor / name).write_bytes(payload)
            checksums.append(f"{hashlib.sha256(payload).hexdigest()}  {name}\n")
        (vendor / "checksums.sha256").write_text("".join(checksums))
        framework = self.repo / ".build/arm64-apple-macosx/release/Sparkle.framework/Versions/B"
        framework.mkdir(parents=True)
        (framework / "Sparkle").write_bytes(b"inert framework")
        (self.repo / ".gitignore").write_text(".build/\nbuild/\n*.dmg\nmock-bin/\nevents.jsonl\n")
        bin_dir = self.repo / "mock-bin"
        bin_dir.mkdir()
        for name in ("xcrun", "codesign", "spctl", "create-dmg", "otool", "install_name_tool", "xattr"):
            tool = bin_dir / name
            tool.write_text(MOCK_TOOL)
            tool.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
        self.git("init", "-q", "-b", "alpha/clipboard-history")
        self.git("config", "user.name", "Packaging Test")
        self.git("config", "user.email", "packaging-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.commit()
        self.before = {name: (self.repo / name).read_bytes()
                       for name in ("docs/appcast.xml", "docs/index.html", "Resources/Info.plist")}

    def git(self, *args):
        return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args],
                              cwd=self.repo, check=True, text=True, capture_output=True).stdout.strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Synthetic packaging fixture")

    def run_script(self, *args, failure=False):
        env = dict(self.env)
        if failure:
            env["SF_TEST_FAIL_NOTARY"] = "1"
        return subprocess.run(["bash", "scripts/build.sh", *args], cwd=self.repo,
                              env=env, text=True, capture_output=True)

    def events(self):
        file = self.repo / "events.jsonl"
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def assert_stable_unchanged(self):
        for name, contents in self.before.items():
            self.assertEqual((self.repo / name).read_bytes(), contents, name)

    def test_alpha_uses_real_plist_and_manual_update_boundary(self):
        result = self.run_script("--alpha")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_stable_unchanged()
        packages = list((self.repo / "build").glob("release-package.*"))
        self.assertEqual(len(packages), 1)
        package = packages[0]
        info = plistlib.loads((package / "speakfree.app/Contents/Info.plist").read_bytes())
        self.assertEqual(info["SFBuildChannel"], "alpha")
        self.assertEqual(info["SFBuildDisplayVersion"], "1.8.0-alpha.1")
        self.assertEqual(info["CFBundleShortVersionString"], "1.8.0")
        self.assertEqual(info["CFBundleVersion"], "1.8.0a1")
        self.assertEqual(info["SFBuildCommit"], self.git("rev-parse", "HEAD"))
        self.assertNotIn("SUFeedURL", info)
        self.assertFalse(info["SUEnableAutomaticChecks"])
        receipt = json.loads((package / "build-receipt.json").read_text())
        self.assertTrue(receipt["manualUpdatesOnly"])
        self.assertEqual(receipt["sourceCommit"], info["SFBuildCommit"])
        checksum = (package / "speakfree-1.8.0-alpha.1.dmg.sha256").read_text().split()[0]
        self.assertEqual(checksum, hashlib.sha256((self.repo / receipt["artifact"]).read_bytes()).hexdigest())
        events = self.events()
        self.assertIn(["xcrun", "notarytool", "submit", receipt["artifact"],
                       "--keychain-profile", "speakfree-notary", "--wait"], events)
        self.assertIn(["xcrun", "stapler", "validate", receipt["artifact"]], events)
        self.assertTrue(any(event[0] == "codesign" and "--options" in event and "runtime" in event
                            for event in events))
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_alpha_source_cannot_accidentally_use_stable_packaging(self):
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("use --alpha", result.stderr)
        self.assertEqual(self.events(), [])
        self.assert_stable_unchanged()

    def test_alpha_requires_prerelease_version(self):
        (self.repo / "Sources/SpeakFreeLib/Version.swift").write_text('public let version = "1.7.2"\n')
        self.commit()
        result = self.run_script("--alpha")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), [])

    def test_invalid_apple_alpha_sequence_is_rejected(self):
        (self.repo / "Sources/SpeakFreeLib/Version.swift").write_text('public let version = "1.8.0-alpha.256"\n')
        self.commit()
        result = self.run_script("--alpha")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("between 1 and 255", result.stderr)
        self.assertEqual(self.events(), [])

    def test_stable_packaging_still_requires_a_release_branch(self):
        (self.repo / "Sources/SpeakFreeLib/Version.swift").write_text('public let version = "1.7.2"\n')
        self.commit()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires main", result.stderr)
        self.assertEqual(self.events(), [])

    def test_dirty_source_rejected_before_build_or_notary(self):
        with (self.repo / "Sources/SpeakFreeLib/Version.swift").open("a") as file:
            file.write("// changed\n")
        result = self.run_script("--alpha")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("commit tracked", result.stderr)
        self.assertEqual(self.events(), [])

    def test_untracked_source_rejected_before_build_or_notary(self):
        (self.repo / "Sources/untracked.swift").write_text("// synthetic\n")
        result = self.run_script("--alpha")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("untracked build inputs", result.stderr)
        self.assertEqual(self.events(), [])

    def test_notarization_failure_never_marks_package_ready(self):
        result = self.run_script("--alpha", failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Alpha package ready", result.stdout)
        self.assertFalse(list((self.repo / "build").rglob("build-receipt.json")))
        self.assertFalse(any(event[:2] == ["xcrun", "stapler"] for event in self.events()))
        self.assert_stable_unchanged()

    def test_existing_artifact_is_preserved(self):
        artifact = self.repo / "speakfree-1.8.0-alpha.1.dmg"
        artifact.write_bytes(b"previous artifact")
        result = self.run_script("--alpha")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(artifact.read_bytes(), b"previous artifact")
        self.assertEqual(self.events(), [])

    def test_alpha_check_catches_stable_feed_drift(self):
        source = self.repo / "docs/appcast.xml"
        source.write_text(source.read_text().replace("1.7.2", "1.7.3"))
        result = subprocess.run(["bash", "scripts/check-version.sh", "--alpha"],
                                cwd=self.repo, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_stable_check_remains_strict(self):
        (self.repo / "Sources/SpeakFreeLib/Version.swift").write_text('public let version = "1.7.2"\n')
        result = subprocess.run(["bash", "scripts/check-version.sh"], cwd=self.repo,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        source = self.repo / "docs/index.html"
        source.write_text(source.read_text().replace("1.7.2", "1.7.3"))
        result = subprocess.run(["bash", "scripts/check-version.sh"], cwd=self.repo,
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
