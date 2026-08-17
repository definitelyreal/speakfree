// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class BoundedFIFOTests: XCTestCase {
    func testRejectsOverflowWithoutDroppingAcceptedGestures() {
        var queue = BoundedFIFO<String>(capacity: 2)

        XCTAssertTrue(queue.append("first"))
        XCTAssertTrue(queue.append("second"))
        XCTAssertFalse(queue.append("overflow"))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.removeFirst(), "first")
        XCTAssertEqual(queue.removeFirst(), "second")
        XCTAssertNil(queue.removeFirst())
    }

    func testRemoveAllAllowsQueueReuse() {
        var queue = BoundedFIFO<Int>(capacity: 1)
        XCTAssertTrue(queue.append(1))
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(queue.append(2))
        XCTAssertEqual(queue.first, 2)
    }
}
