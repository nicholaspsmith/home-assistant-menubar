import XCTest
@testable import HomesteadCore

final class ReconnectPolicyTests: XCTestCase {
    func testBackoffDoublesThenHoldsAtThirtySeconds() {
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 6, 20].map(ReconnectPolicy.delay(attempt:)),
                       [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testNegativeAttemptIsTreatedAsTheFirst() {
        XCTAssertEqual(ReconnectPolicy.delay(attempt: -3), 1)
    }
}
