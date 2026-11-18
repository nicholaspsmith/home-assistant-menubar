// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class LevelMathTests: XCTestCase {
    func testBrightnessAttributeConvertsToFraction() {
        XCTAssertEqual(LevelMath.fraction(brightness: .number(255)), 1.0, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(brightness: .number(128)), 0.502, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(brightness: nil), 0)
        XCTAssertEqual(LevelMath.fraction(brightness: .null), 0)
    }

    func testBrightnessPercentNeverReachesZero() {
        // 0% would be turn_off in disguise; the switch owns off, the slider does not.
        XCTAssertEqual(LevelMath.brightnessPct(from: 0), 1)
        XCTAssertEqual(LevelMath.brightnessPct(from: 0.004), 1)
        XCTAssertEqual(LevelMath.brightnessPct(from: 0.5), 50)
        XCTAssertEqual(LevelMath.brightnessPct(from: 1), 100)
        XCTAssertEqual(LevelMath.brightnessPct(from: 2), 100)
    }

    func testFanPercentageSnapsToTheDeviceStep() {
        // A three-speed fan has step 33.333…; anything else is rejected by HA.
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.4, step: 100.0 / 3.0), 33)
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.6, step: 100.0 / 3.0), 67)
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.9, step: 100.0 / 3.0), 100)
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.42, step: nil), 42)
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.42, step: 0), 42)
    }

    func testAFullCoverSliderIsAShutShade() {
        // HA's position runs 0 shut … 100 open; the bar fills as the shade
        // comes down, so an empty bar is a fully open shade.
        XCTAssertEqual(LevelMath.coverPosition(from: 0), 100)
        XCTAssertEqual(LevelMath.coverPosition(from: 0.25), 75)
        XCTAssertEqual(LevelMath.coverPosition(from: 1), 0)
    }

    func testCoverPositionFillsTheBarAsTheShadeCloses() {
        XCTAssertEqual(LevelMath.fraction(coverPosition: .number(100)), 0, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(coverPosition: .number(75)), 0.25, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(coverPosition: .number(0)), 1, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(coverPosition: .number(140)), 0, accuracy: 0.001)
        // No report yet: an empty bar, as for every other slider.
        XCTAssertEqual(LevelMath.fraction(coverPosition: nil), 0)
    }

    func testACoverSliderLandsWhereItWasLetGo() {
        for position in [0, 1, 33, 50, 99, 100] {
            let fraction = LevelMath.fraction(coverPosition: .number(Double(position)))
            XCTAssertEqual(LevelMath.coverPosition(from: fraction), position)
        }
    }

    func testPercentageAttributeConvertsToFraction() {
        XCTAssertEqual(LevelMath.fraction(percentage: .number(67)), 0.67, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(percentage: nil), 0)
    }
}
