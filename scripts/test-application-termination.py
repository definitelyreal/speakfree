#!/usr/bin/env python3
# ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
"""Compile the production helper into an isolated, inert AppKit lifecycle probe.

No speakfree delegate, config, clipboard, microphone, windows, or hotkeys are used.
The watchdog exits only the synthetic child; the real app is never addressed.
"""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
HARNESS = r'''
import AppKit
import Darwin

func report(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

final class Delegate: NSObject, NSApplicationDelegate {
    let mode: String
    var requestReturned = false
    init(mode: String) { self.mode = mode }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if mode == "external-quit" {
            requestReturned = true
            report("ready-for-external-quit")
            return
        }
        DispatchQueue.main.async {
            report("dispatch-request")
            if self.mode == "direct-control" {
                NSApplication.shared.terminate(nil)
            } else {
                ApplicationTermination.request()
            }
            self.requestReturned = true
            report("request-returned")
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        report("should-terminate")
        if mode == "timeout-cancel" {
            // The production history timeout also uses main.asyncAfter.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard self.requestReturned else { exit(72) }
                report("timeout-cancel")
                sender.reply(toApplicationShouldTerminate: false)
                DispatchQueue.main.async {
                    report("main-queue-alive-after-cancel")
                    exit(0)
                }
            }
        } else {
            // Model a disk drain followed by its main-thread completion.
            DispatchQueue.global().async {
                DispatchQueue.main.async {
                    guard self.requestReturned else { exit(72) }
                    report("drain-reply")
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        report("will-terminate")
    }
}

@main struct Probe {
    static func main() {
        if CommandLine.arguments[1] == "request-quit" {
            guard let pid = Int32(CommandLine.arguments[2]),
                  let target = NSRunningApplication(processIdentifier: pid),
                  target.executableURL?.standardizedFileURL ==
                    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL else {
                report("target-identity-mismatch")
                exit(74)
            }
            let accepted = target.terminate()
            report(accepted ? "normal-quit-accepted" : "normal-quit-refused")
            exit(accepted ? 0 : 75)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = Delegate(mode: CommandLine.arguments[1])
        app.delegate = delegate
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            report("watchdog-expired")
            exit(73)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
'''


class ApplicationTerminationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="speakfree-termination-test-")
        cls.addClassCleanup(cls.directory.cleanup)
        stage = pathlib.Path(cls.directory.name)
        fixture = stage / "Probe.swift"
        fixture.write_text(HARNESS)
        cls.binary = stage / "termination-probe"
        subprocess.run([
            "/usr/bin/nice", "-n", "10", "/usr/bin/xcrun", "swiftc", "-j", "2",
            str(ROOT / "Sources/SpeakFreeLib/ApplicationTermination.swift"),
            str(fixture), "-o", str(cls.binary),
        ], check=True, capture_output=True, text=True, timeout=60)

    def run_probe(self, mode):
        return subprocess.run([str(self.binary), mode], capture_output=True,
                              text=True, timeout=8)

    def test_dispatch_originated_drain_completes(self):
        result = self.run_probe("drain")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "dispatch-request", "request-returned", "should-terminate",
            "drain-reply", "will-terminate",
        ])

    def test_dispatch_originated_timeout_can_cancel(self):
        result = self.run_probe("timeout-cancel")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "dispatch-request", "request-returned", "should-terminate",
            "timeout-cancel", "main-queue-alive-after-cancel",
        ])

    def test_original_dispatch_termination_reproduces_starvation(self):
        result = self.run_probe("direct-control")
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "dispatch-request", "should-terminate", "watchdog-expired",
        ])

    def test_external_normal_quit_drains_without_dispatch_starvation(self):
        # Only this synthetic child's exact PID and executable may be targeted.
        child = subprocess.Popen([str(self.binary), "external-quit"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready = child.stdout.readline().strip()
        self.assertEqual(ready, "ready-for-external-quit")
        request = subprocess.run([str(self.binary), "request-quit", str(child.pid)],
                                 capture_output=True, text=True, timeout=8)
        output, error = child.communicate(timeout=8)
        self.assertEqual(request.returncode, 0, request.stdout + request.stderr)
        self.assertEqual(request.stdout.strip(), "normal-quit-accepted")
        self.assertEqual(child.returncode, 0, output + error)
        self.assertEqual(output.splitlines(), ["should-terminate", "drain-reply", "will-terminate"])


if __name__ == "__main__":
    unittest.main()
