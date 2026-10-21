// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class GaugeTests: XCTestCase {
    /// A battery: green from 60 up, yellow at 30, red at 10 and below.
    private let battery = GaugeSpec(green: 60, yellow: 30, red: 10)

    func testThresholdsAreTheirOwnColours() {
        XCTAssertEqual(battery.color(for: 60), GaugeSpec.success)
        XCTAssertEqual(battery.color(for: 30), GaugeSpec.warning)
        XCTAssertEqual(battery.color(for: 10), GaugeSpec.error)
    }

    func testBeyondTheOutermostThresholdsTheColourHolds() {
        XCTAssertEqual(battery.color(for: 100), GaugeSpec.success)
        XCTAssertEqual(battery.color(for: 250), GaugeSpec.success)
        XCTAssertEqual(battery.color(for: 3), GaugeSpec.error)
        XCTAssertEqual(battery.color(for: -40), GaugeSpec.error)
    }

    func testBetweenThresholdsTheColourBlends() throws {
        // Half-way from yellow (30) to green (60).
        let mid = try XCTUnwrap(battery.color(for: 45))
        XCTAssertEqual(mid.red, (GaugeSpec.warning.red + GaugeSpec.success.red) / 2, accuracy: 1e-9)
        XCTAssertEqual(mid.green, (GaugeSpec.warning.green + GaugeSpec.success.green) / 2, accuracy: 1e-9)
        XCTAssertEqual(mid.blue, (GaugeSpec.warning.blue + GaugeSpec.success.blue) / 2, accuracy: 1e-9)

        // A quarter of the way from red (10) to yellow (30): mostly red.
        let low = try XCTUnwrap(battery.color(for: 15))
        XCTAssertEqual(low.green, GaugeSpec.error.green + (GaugeSpec.warning.green - GaugeSpec.error.green) * 0.25,
                       accuracy: 1e-9)

        // Draining from 60 to 10 fades a little at a time: no step between
        // neighbouring values jumps, the way a banded gauge would.
        let fade = stride(from: 60.0, through: 10, by: -1).compactMap { battery.color(for: $0) }
        for (a, b) in zip(fade, fade.dropFirst()) {
            XCTAssertLessThan(max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)), 0.03)
        }
    }

    func testThresholdsThatRunTheOtherWay() {
        // A temperature: green low, red high.
        let heat = GaugeSpec(min: 0, max: 50, green: 0, yellow: 25, red: 40)
        XCTAssertEqual(heat.color(for: -5), GaugeSpec.success)
        XCTAssertEqual(heat.color(for: 45), GaugeSpec.error)
        XCTAssertEqual(heat.color(for: 25), GaugeSpec.warning)
    }

    func testWithoutYellowGreenBlendsStraightToRed() throws {
        let gauge = GaugeSpec(green: 50, red: 0)
        let mid = try XCTUnwrap(gauge.color(for: 25))
        XCTAssertEqual(mid.blue, (GaugeSpec.error.blue + GaugeSpec.success.blue) / 2, accuracy: 1e-9)
    }

    func testNoSeverityHasNoColour() {
        XCTAssertNil(GaugeSpec().color(for: 50))
    }

    func testTheArcFillsBetweenMinAndMax() {
        XCTAssertEqual(battery.fraction(of: 85), 0.85, accuracy: 1e-9)
        XCTAssertEqual(battery.fraction(of: 140), 1)
        XCTAssertEqual(battery.fraction(of: -3), 0)
        let watts = GaugeSpec(min: 100, max: 300)
        XCTAssertEqual(watts.fraction(of: 150), 0.25, accuracy: 1e-9)
        XCTAssertEqual(GaugeSpec(min: 5, max: 5).fraction(of: 5), 0)
    }

    func testCardFieldsAreRead() throws {
        let card = try JSONValue.parse(Data(#"""
        {"type":"gauge","entity":"sensor.back_door_battery","min":10,"max":90,
         "severity":{"green":60,"yellow":30,"red":10}}
        """#.utf8))
        XCTAssertEqual(GaugeSpec(card: card), GaugeSpec(min: 10, max: 90, green: 60, yellow: 30, red: 10))
        XCTAssertEqual(GaugeSpec(card: .object([:])), GaugeSpec(min: 0, max: 100))
    }
}
