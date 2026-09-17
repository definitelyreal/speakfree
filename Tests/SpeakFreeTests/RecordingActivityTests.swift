// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
import XCTest
@testable import SpeakFreeLib

final class RecordingActivityTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/synthetic-recording-activity")
    private var audio: URL { directory.appendingPathComponent("recording-2026-01-01-120000-A.wav") }

    func testEveryKnownSidecarBelongsToItsWAVGroup() {
        for suffix in ["txt", "raw.txt", "meta.json", "bt.wav", "bt.raw.txt", "builtin.raw.txt", "whisper.txt", "parakeet.txt"] {
            XCTAssertEqual(RecordingActivity.group(for: audio), RecordingActivity.group(for:
                audio.deletingPathExtension().appendingPathExtension(suffix)))
        }
    }

    func testActiveAtSnapshotStaysExcludedAfterLeaseEnds() throws {
        let activity = RecordingActivity()
        let lease = try activity.acquire(audio)
        let removal = activity.beginRemoval(in: directory)
        lease.release()
        XCTAssertFalse(removal.claim(audio))
        removal.finish()
        XCTAssertTrue(activity.beginRemoval(in: directory).claim(audio))
    }

    func testNewAcquisitionDuringEnumerationStaysExcludedAfterCompletion() throws {
        let activity = RecordingActivity()
        let removal = activity.beginRemoval(in: directory)
        let lease = try activity.acquire(audio)
        lease.release()
        XCTAssertFalse(removal.claim(audio))
    }

    func testClaimWinsAtomicallyAndBlocksAllGroupReadersUntilRemovalEnds() throws {
        let activity = RecordingActivity()
        let removal = activity.beginRemoval(in: directory)
        XCTAssertTrue(removal.claim(audio))
        XCTAssertTrue(removal.claim(audio.deletingPathExtension().appendingPathExtension("whisper.txt")))
        XCTAssertThrowsError(try activity.acquire(audio))
        XCTAssertThrowsError(try activity.acquire(audio.deletingPathExtension().appendingPathExtension("txt")))
        let different = directory.appendingPathComponent("recording-2026-01-01-120001-new.wav")
        let fresh = try activity.acquire(different)
        fresh.release()
        removal.finish()
        let available = try activity.acquire(audio)
        available.release()
    }

    func testChildLeaseOutlivesParentAndStaleReleaseCannotEndNewGeneration() throws {
        let activity = RecordingActivity()
        let parent = try activity.acquire(audio)
        let child = try activity.acquire(audio)
        XCTAssertEqual(parent.generation, child.generation)
        parent.release()
        let removal = activity.beginRemoval(in: directory)
        XCTAssertFalse(removal.claim(audio))
        removal.finish(); child.release()
        let next = try activity.acquire(audio)
        XCTAssertNotEqual(parent.generation, next.generation)
        parent.release(); child.release()
        XCTAssertFalse(activity.beginRemoval(in: directory).claim(audio))
        next.release()
    }

    func testThrownScopeAndRemovalDeinitReleaseTheirExactAdmissions() throws {
        enum Failure: Error { case synthetic }
        let activity = RecordingActivity()
        func failWhileLeased() throws {
            let lease = try activity.acquire(audio)
            defer { lease.release() }
            throw Failure.synthetic
        }
        XCTAssertThrowsError(try failWhileLeased())
        do {
            let removal = activity.beginRemoval(in: directory)
            XCTAssertTrue(removal.claim(audio))
        }
        let lease = try activity.acquire(audio)
        lease.release()
    }

    func testIndependentRemovalCannotStealAnExistingClaim() {
        let activity = RecordingActivity()
        let first = activity.beginRemoval(in: directory)
        let second = activity.beginRemoval(in: directory)
        XCTAssertTrue(first.claim(audio))
        XCTAssertFalse(second.claim(audio))
        first.finish()
        XCTAssertTrue(second.claim(audio))
        XCTAssertFalse(second.claim(URL(fileURLWithPath: "/another-directory/example.wav")))
    }
}
