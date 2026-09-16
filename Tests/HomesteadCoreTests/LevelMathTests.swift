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

    func testCoverPositionSpansTheFullRange() {
        XCTAssertEqual(LevelMath.coverPosition(from: 0), 0)
        XCTAssertEqual(LevelMath.coverPosition(from: 0.5), 50)
        XCTAssertEqual(LevelMath.coverPosition(from: 1), 100)
    }

    func testPercentageAttributeConvertsToFraction() {
        XCTAssertEqual(LevelMath.fraction(percentage: .number(67)), 0.67, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(percentage: nil), 0)
    }
}
