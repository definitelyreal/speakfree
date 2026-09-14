#!/usr/bin/env python3
# ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
"""Inert shell-flow tests: fake processes, fake staged CLI, and temporary app/Trash."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent

INSTALL_HARNESS = r'''
source "$SCRIPTS/guarded-install.sh"
SF_INSTALLED_APP="$TEST_ROOT/installed.app"
codesign() { echo "verify:$*" >> "$TRACE"; return "${VERIFY_STATUS:-0}"; }
pgrep() {
    if [ "${QUERY_STATUS:-0}" != 0 ]; then return "$QUERY_STATUS"; fi
    if [ "${QUERY_INVALID:-0}" = 1 ]; then echo invalid; return 0; fi
    if [ "${QUERY_EMPTY:-0}" = 1 ]; then return 0; fi
    if [ -e "$TEST_ROOT/launched" ]; then echo 4243; return 0; fi
    if [ "${NO_PROCESS:-0}" = 1 ]; then
        if [ "${APPEARS_DURING_NO_GUARD:-0}" = 1 ] && [ -e "$TEST_ROOT/absent-observed" ]; then
            echo 4244
            return 0
        fi
        touch "$TEST_ROOT/absent-observed"
        return 1
    fi
    if [ ! -e "$TEST_ROOT/signaled" ] || [ "${STUCK:-0}" = 1 ]; then echo 4242; return 0; fi
    return 1
}
kill() {
    echo "signal:$*" >> "$TRACE"
    touch "$TEST_ROOT/signaled"
    return "${SIGNAL_STATUS:-0}"
}
sleep() { :; }
open() { echo launch >> "$TRACE"; touch "$TEST_ROOT/launched"; }
sf_move_old_app_to_trash() {
    echo trash >> "$TRACE"
    [ "${TRASH_STATUS:-0}" = 0 ] || return "$TRASH_STATUS"
    [ "${TRASH_NOOP:-0}" = 0 ] || return 0
    /bin/mv "$SF_INSTALLED_APP" "$TEST_ROOT/fake-trash.app"
}
cp() {
    echo copy >> "$TRACE"
    [ "${COPY_STATUS:-0}" = 0 ] || return "$COPY_STATUS"
    [ "$3" = "$TEST_ROOT/installed.app" ] || return 99
    /bin/cp "$@"
}
sf_install_staged_app "$TEST_ROOT/staged.app" inert-test
'''

FLEET_HARNESS = r'''
source "$SCRIPTS/dev-deploy-fleet.sh"
sf_initialize_stage() { echo initialize >> "$TRACE"; SF_STAGE_ROOT="$TEST_ROOT"; }
sf_build_and_vendor() { echo build >> "$TRACE"; return "${BUILD_STATUS:-0}"; }
sf_stage_remote() {
    echo "stage:$1" >> "$TRACE"
    [ "${FAIL_STAGE:-}" != "$1" ] || return 1
    SF_NEW_REMOTE_STAGE=/tmp/speakfree-fleet.inert
}
sf_install_local() { echo install:local >> "$TRACE"; return "${LOCAL_STATUS:-0}"; }
sf_install_remote() {
    echo "install:$1" >> "$TRACE"
    [ "${FAIL_INSTALL:-}" != "$1" ] || return 1
}
sf_cleanup_stage() { echo cleanup >> "$TRACE"; }
sf_fleet_main
'''


TRANSPORT_HARNESS = r'''
source "$SCRIPTS/dev-deploy-fleet.sh"
SF_STAGE_ROOT="$TEST_ROOT"
SF_ARCHIVE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ssh() {
    echo "ssh:$*" >> "$TRACE"
    case "$*" in *mktemp*) echo /tmp/speakfree-fleet.inert;; esac
    return "${SSH_STATUS:-0}"
}
scp() { echo "scp:$*" >> "$TRACE"; return "${SCP_STATUS:-0}"; }
sf_stage_remote inert-host
sf_install_remote inert-host "$SF_NEW_REMOTE_STAGE"
'''


class GuardedDeployTests(unittest.TestCase):
    def run_flow(self, harness=INSTALL_HARNESS, **overrides):
        with tempfile.TemporaryDirectory(prefix="speakfree-deploy-test-") as directory:
            root = pathlib.Path(directory)
            executable = root / "staged.app/Contents/MacOS/speakfree"
            executable.parent.mkdir(parents=True)
            executable.write_text("""#!/bin/bash
if [ "$1" = --help ]; then exit 0; fi
[ "$1" = prepare-update ] && [ "$2" = --timeout ] && [ "$3" = 600 ] || exit 64
printf 'guard\\n' >> "$TRACE"
printf '%s\\n' "${GUARD_OUTPUT-SPEAKFREE_UPDATE_READY}"
exit "${GUARD_STATUS:-0}"
""")
            executable.chmod(0o700)
            (root / "installed.app").mkdir()
            (root / "installed.app/original").write_bytes(b"original app fixture")
            trace = root / "trace"
            trace.touch()
            env = {key: value for key, value in os.environ.items()
                   if key not in ("SPEAKFREE_CONFIG_DIR", "M3_ONLY")}
            env.update(SCRIPTS=str(SCRIPTS), TEST_ROOT=str(root), TRACE=str(trace))
            env.update({key: str(value) for key, value in overrides.items()})
            result = subprocess.run(["/bin/bash", "-c", harness], env=env,
                                    capture_output=True, text=True, timeout=10)
            return result, trace.read_text().splitlines(), {
                "original_installed": (root / "installed.app/original").exists(),
                "original_in_fake_trash": (root / "fake-trash.app/original").exists(),
            }

    def assert_no_interruption(self, result, events, files):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(e.startswith("signal:") for e in events))
        self.assertNotIn("trash", events)
        self.assertNotIn("copy", events)
        self.assertNotIn("launch", events)
        self.assertTrue(files["original_installed"])

    def test_positive_receipt_precedes_only_graceful_signal_and_trash_before_copy(self):
        result, events, files = self.run_flow()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ["guard", "signal:-TERM 4242", "trash", "copy", "launch"]
        self.assertEqual([e for e in events if e in expected], expected)
        self.assertEqual([e for e in events if e.startswith("signal:")], ["signal:-TERM 4242"])
        self.assertTrue(files["original_in_fake_trash"])
        self.assertFalse(files["original_installed"])

    def test_cancel_timeout_unknown_and_usage_fail_closed_even_with_ready_text(self):
        for status in (1, 2, 3, 4, 64):
            with self.subTest(status=status):
                self.assert_no_interruption(*self.run_flow(GUARD_STATUS=status))

    def test_zero_exit_without_exact_receipt_does_not_stop(self):
        for output in ("", "usage: unsupported command", "SPEAKFREE_UPDATE_READY extra",
                       "noise\nSPEAKFREE_UPDATE_READY"):
            with self.subTest(output=output):
                self.assert_no_interruption(*self.run_flow(GUARD_OUTPUT=output))

    def test_custom_config_cannot_authorize_production_stop(self):
        result, events, files = self.run_flow(SPEAKFREE_CONFIG_DIR="/tmp/inert-custom-config")
        self.assert_no_interruption(result, events, files)
        self.assertNotIn("guard", events)

    def test_unknown_or_malformed_process_state_does_not_stop(self):
        for options in ({"QUERY_STATUS": 2}, {"QUERY_INVALID": 1}, {"QUERY_EMPTY": 1}):
            with self.subTest(options=options):
                self.assert_no_interruption(*self.run_flow(**options))

    def test_stuck_app_is_never_forced_or_replaced(self):
        result, events, files = self.run_flow(STUCK=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("180 seconds", result.stderr)
        self.assertEqual([e for e in events if e.startswith("signal:")], ["signal:-TERM 4242"])
        self.assertNotIn("trash", events)
        self.assertNotIn("copy", events)
        self.assertTrue(files["original_installed"])

    def test_failed_signal_leaves_bundle_intact(self):
        result, events, files = self.run_flow(SIGNAL_STATUS=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("trash", events)
        self.assertTrue(files["original_installed"])

    def test_failed_or_noop_trash_never_copies_over_old_bundle(self):
        for options in ({"TRASH_STATUS": 1}, {"TRASH_NOOP": 1}):
            with self.subTest(options=options):
                result, events, files = self.run_flow(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("trash", events)
                self.assertNotIn("copy", events)
                self.assertNotIn("launch", events)
                self.assertTrue(files["original_installed"])

    def test_copy_failure_does_not_launch_and_preserves_old_app_in_fake_trash(self):
        result, events, files = self.run_flow(COPY_STATUS=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("launch", events)
        self.assertTrue(files["original_in_fake_trash"])

    def test_already_stopped_process_skips_warning_and_signal(self):
        result, events, _ = self.run_flow(NO_PROCESS=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("guard", events)
        self.assertFalse(any(e.startswith("signal:") for e in events))
        self.assertIn("copy", events)

    def test_process_appearing_in_no_warning_branch_aborts_without_signal(self):
        result, events, files = self.run_flow(NO_PROCESS=1, APPEARS_DURING_NO_GUARD=1)
        self.assert_no_interruption(result, events, files)
        self.assertNotIn("guard", events)
        self.assertIn("app started after the initial check", result.stderr)

    def test_invalid_bundle_fails_before_guard(self):
        result, events, files = self.run_flow(VERIFY_STATUS=1)
        self.assert_no_interruption(result, events, files)
        self.assertNotIn("guard", events)

    def test_default_fleet_stages_all_hosts_before_any_install(self):
        result, events, _ = self.run_flow(FLEET_HARNESS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["initialize", "build", "stage:movie@STUDIO_TAILSCALE_HOST", "stage:ark",
                                  "install:local", "install:movie@STUDIO_TAILSCALE_HOST", "install:ark", "cleanup"])

    def test_build_or_remote_staging_failure_never_interrupts_any_host(self):
        for options in ({"BUILD_STATUS": 1}, {"FAIL_STAGE": "movie@STUDIO_TAILSCALE_HOST"},
                        {"FAIL_STAGE": "ark"}):
            with self.subTest(options=options):
                result, events, _ = self.run_flow(FLEET_HARNESS, **options)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(e.startswith("install:") for e in events))

    def test_local_abort_does_not_continue_to_remote_stops(self):
        result, events, _ = self.run_flow(FLEET_HARNESS, LOCAL_STATUS=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([e for e in events if e.startswith("install:")], ["install:local"])

    def test_remote_abort_stops_fleet_sequence_and_does_not_claim_cleanup(self):
        result, events, _ = self.run_flow(FLEET_HARNESS, FAIL_INSTALL="movie@STUDIO_TAILSCALE_HOST")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("install:ark", events)
        self.assertNotIn("cleanup", events)

    def test_all_stage_transfer_and_install_commands_bound_ssh_transport(self):
        result, events, _ = self.run_flow(TRANSPORT_HARNESS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([event.split(":", 1)[0] for event in events], ["ssh", "scp", "ssh", "ssh"])
        for event in events:
            for option in ("BatchMode=yes", "ConnectTimeout=10", "ServerAliveInterval=10", "ServerAliveCountMax=3"):
                self.assertIn("-o " + option, event)

    def test_transport_failure_aborts_before_install_command(self):
        for options, expected_commands in (({"SSH_STATUS": 255}, ["ssh"]),
                                           ({"SCP_STATUS": 1}, ["ssh", "scp"])):
            with self.subTest(options=options):
                result, events, _ = self.run_flow(TRANSPORT_HARNESS, **options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([event.split(":", 1)[0] for event in events], expected_commands)

    def test_explicit_local_only_override_and_invalid_value(self):
        result, events, _ = self.run_flow(FLEET_HARNESS, M3_ONLY=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["initialize", "build", "install:local", "cleanup"])
        result, events, _ = self.run_flow(FLEET_HARNESS, M3_ONLY="typo")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
