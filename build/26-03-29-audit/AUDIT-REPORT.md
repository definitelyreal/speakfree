# Speakfree v2 Audit Report — 2026-03-29

Branch: `feat/settings-window-v2` (49 commits)

## Audit Summary

| Audit | Status | Key Findings |
|-------|--------|-------------|
| SwiftLint | Done | 75 errors, 147 warnings — most noise (short var names). 5 force casts actionable. |
| Security | Done | 5 critical (force casts on AX API), 7 high, 7 medium |
| Deprecation | Done | Carbon HIToolbox in TextInserter is most concerning. Timing APIs are secondary. |
| TSan Build | Done | Compiles clean with --sanitize=thread. Runtime testing needs interactive session. |
| Instruments Leaks | Needs GUI | Run: `leaks --atExit -- .build/debug/speakfree` or use Instruments |
| Time Profiler | Needs GUI | Use Instruments > Time Profiler during dictation |
| Accessibility Inspector | Needs GUI | Use Xcode > Accessibility Inspector on Settings window |

## Actionable Fixes (Prioritized)

### P0 — Force Casts (crash risk)

These force casts on AX API `CFTypeRef` returns can crash if the type system is violated:

1. **TextInserter.swift:57** — `element as! AXUIElement`
2. **StatusBarController.swift:62** — `element as! AXUIElement`
3. **AppDelegate.swift:316** — `element as! AXUIElement`
4. **AppDelegate.swift:336** — another force cast
5. **CorrectionMonitor.swift:124** — `rangeValue as! AXValue`

Fix: Replace `as!` with conditional `as?` + guard.

### P1 — Thread Safety

6. **AudioRecorder.swift:74-76** — `needsTapReinstall` accessed from multiple threads without lock
7. **HotkeyManager.swift:133,160** — `modifierPressedAt` accessed from event tap callback + NSEvent monitor without sync
8. **WhisperEngine.swift:26-48** — `context` checked and used without lock between loadModel/unloadModel

### P2 — Input Validation

9. **WhisperEngine.swift:103-106** — `suppressRegex` passed to C library without validation
10. **ModelDownloader.swift** — Directory created with default permissions (should be 700)

### P3 — Code Quality (SwiftLint)

11. **AppDelegate** — 554 lines body (limit 350), function at line 408 is 105 lines
12. **StatusBarController** — 418 lines body (limit 350), function at line 115 is 111 lines
13. **SettingsWindow** — 460 lines body (limit 350)
14. Various lines >200 chars in HelpController, VocabularyMigration, AppDelegate

### Deferred — Not fixing now

- **Carbon HIToolbox** (TextInserter) — Would require major rewrite. Works on Apple Silicon currently.
- **CFAbsoluteTimeGetCurrent** — Functional, non-urgent modernization.
- **Short variable names** (i, x, y, etc.) — Standard for loops/coordinates, suppressing via config.
- **Certificate pinning** — Downloads from huggingface.co, standard TLS is sufficient.
- **Logging redaction** — Beta-only feature, acceptable for now.
