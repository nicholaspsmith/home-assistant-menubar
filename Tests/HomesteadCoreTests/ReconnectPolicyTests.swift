// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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
