<!-- ai:processed | session: 5b06900b-1498-4764-a786-48f408c36626 | date: 2026-06-10 -->
# Root-cause: `ParakeetEngineTests.testUnknownModelIsNotDownloaded`

**Task:** T0.2 (Truthful test suite). This was the one failing test in the suite NOT in the
documented known-fail list — the audit flagged it as a possible real regression. This note records
the investigation and the fix.

## Verdict

**Real product bug.** `ParakeetModelManager.isModelDownloaded(_:)` reported an unknown/typo'd model
id as "downloaded" whenever the genuine v3 weights were cached. Small, safe one-line fix applied to
the product (not the test).

## The failing test

```swift
func testUnknownModelIsNotDownloaded() {
    XCTAssertFalse(ParakeetModelManager.shared.isModelDownloaded("parakeet-tdt-0.6b-v9-nonexistent"))
}
```

It asserts that an id the catalog never advertised is not "downloaded."

## Root cause

`isModelDownloaded` (added in `ca61e52`, unchanged since) resolved the id to a FluidAudio version and
then checked the on-disk cache for *that version's* directory:

```swift
public func isModelDownloaded(_ modelName: String) -> Bool {
    let v = version(for: modelName)                                  // unknown id → .v3 (silent default)
    return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: v), version: v)
}
```

`version(for:)` maps any unrecognized id to `.v3`:

```swift
private func version(for modelName: String) -> AsrModelVersion {
    EngineCatalog.versionString(forParakeetModelID: modelName) == "v2" ? .v2 : .v3
}
```

So for `"parakeet-tdt-0.6b-v9-nonexistent"`:
1. `versionString(...)` returns `nil` (not "v2") → `version(for:)` defaults to `.v3`.
2. `isModelDownloaded` then checks the **v3 cache directory**, ignoring the actual id.
3. On any machine where the real v3 weights are cached, that directory exists → returns `true`.

The test therefore fails on exactly the machines that have the v3 model downloaded. This dev machine
does:

```
$ ls ~/Library/Application\ Support/FluidAudio/Models/
parakeet-tdt-0.6b-v2   parakeet-tdt-0.6b-v3   silero-vad   speaker-diarization
```

It is environment-dependent in *trigger* (needs v3 cached to fail) but the underlying defect is
real and machine-independent: **`isModelDownloaded` performs no id validation.**

## Why this is a genuine defect, not just a brittle test

Every other network/cache-touching method on `ParakeetModelManager` — `ensureDownloaded`,
`downloadOnly`, `loadDownloadedModels` — already guards with `isKnownModelID(...)` and throws
`TranscriptionEngineError.modelAssetsMissing` for unrecognized ids. That guard exists specifically
because `version(for:)` silently defaults unknown ids to a real v3 download/load. `isModelDownloaded`
was simply overlooked when those guards were added (the `isKnownModelID` helper and the sibling guards
landed in the Parakeet adversarial rounds `6261805`/`8a139c3`/`b94984a`; `isModelDownloaded` kept its
original ungated form from `ca61e52`).

Consequence of the bug in product code: a tampered or typo'd `parakeetModel` config value would make
`isModelDownloaded` answer `true` (when v3 is cached), so UI/launch paths that branch on it would skip
the download/validation step and treat a catalog-unknown id as ready — the exact "reports an asset the
catalog never advertised exists" failure mode the sibling guards were added to prevent.

## Fix (product, small + safe)

Add the same `isKnownModelID` guard the sibling methods already use:

```swift
public func isModelDownloaded(_ modelName: String) -> Bool {
    guard isKnownModelID(modelName) else { return false }
    let v = version(for: modelName)
    return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: v), version: v)
}
```

- **Correct:** unknown id → `false` regardless of cache state.
- **Consistent:** matches `ensureDownloaded`/`downloadOnly`/`loadDownloadedModels`.
- **Non-breaking:** the catalog (`EngineCatalog.parakeetModels`) contains the two real ids
  (`parakeet-tdt-0.6b-v3`, `parakeet-tdt-0.6b-v2`), so the consistency test
  (`testIsModelDownloadedDoesNotThrowAndIsConsistent`, which queries the known v3 id) still passes —
  it just stops returning a false positive for catalog-unknown ids.

## Proof

```
$ xcrun swift test --filter ParakeetEngineTests
Test Case '-[OpenWisprTests.ParakeetEngineTests testUnknownModelIsNotDownloaded]' passed (0.000 seconds).
Test Case '-[OpenWisprTests.ParakeetEngineTests testIsModelDownloadedDoesNotThrowAndIsConsistent]' passed (0.001 seconds).
Test Suite 'ParakeetEngineTests' passed
	 Executed 16 tests, with 0 failures (0 unexpected)
```

---
_Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626_
