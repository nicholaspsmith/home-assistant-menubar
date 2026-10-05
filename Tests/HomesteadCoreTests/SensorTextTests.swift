// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class SensorTextTests: XCTestCase {
    private func sensor(_ state: String, deviceClass: String? = nil, unit: String? = nil) -> EntityState {
        var attributes: [String: JSONValue] = [:]
        if let deviceClass { attributes["device_class"] = .string(deviceClass) }
        if let unit { attributes["unit_of_measurement"] = .string(unit) }
        return EntityState(state: state, attributes: attributes)
    }

    func testBinarySensorsUseTheirDeviceClassWording() {
        XCTAssertEqual(SensorText.text(sensor("off", deviceClass: "problem")), "OK")
        XCTAssertEqual(SensorText.text(sensor("on", deviceClass: "problem")), "Problem")
        XCTAssertEqual(SensorText.text(sensor("on", deviceClass: "connectivity")), "Connected")
        XCTAssertEqual(SensorText.text(sensor("off", deviceClass: "running")), "Not running")
        XCTAssertEqual(SensorText.text(sensor("on")), "On")
    }

    func testNumbersLoseAPointlessDecimal() {
        XCTAssertEqual(SensorText.text(sensor("170.0", unit: "W")), "170 W")
        XCTAssertEqual(SensorText.text(sensor("30.97", unit: "%")), "30.97%")
        XCTAssertEqual(SensorText.text(sensor("75.2", unit: "°F")), "75.2 °F")
    }

    func testTimestampsAreRelative() {
        let now = ISO8601DateFormatter().date(from: "2026-10-05T14:45:10Z")!
        XCTAssertEqual(SensorText.text(sensor("2026-10-05T08:45:10+00:00", deviceClass: "timestamp"), now: now), "6 h ago")
        XCTAssertEqual(SensorText.text(sensor("2026-10-06T08:45:00+00:00", deviceClass: "timestamp"), now: now), "in 17 h")
    }

    func testDurationsAndEnums() {
        XCTAssertEqual(SensorText.text(sensor("1214402.375", deviceClass: "duration", unit: "s")), "14 d")
        XCTAssertEqual(SensorText.text(sensor("create_backup", deviceClass: "enum")), "Create backup")
    }
}
