// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class ServiceCallTests: XCTestCase {
    private let light = Device(entityId: "light.desk", displayName: "Desk", kind: .light)
    private let fan = Device(entityId: "fan.office", displayName: "Fan", kind: .fan)
    private let heater = Device(entityId: "switch.heater", displayName: "Heater", kind: .toggle)
    private let garage = Device(entityId: "cover.garage", displayName: "Garage", kind: .cover(positionable: true))
    private let blind = Device(entityId: "cover.blind", displayName: "Blind", kind: .cover(positionable: false))
    private let sensor = Device(entityId: "sensor.temp", displayName: "Temp", kind: .sensor)

    func testToggleUsesTheDomainsOwnServices() {
        XCTAssertEqual(ServiceCall.toggle(light, on: true),
                       ServiceCall(domain: "light", service: "turn_on", entityId: "light.desk", serviceData: [:]))
        XCTAssertEqual(ServiceCall.toggle(heater, on: false),
                       ServiceCall(domain: "switch", service: "turn_off", entityId: "switch.heater", serviceData: [:]))
        XCTAssertEqual(ServiceCall.toggle(garage, on: true),
                       ServiceCall(domain: "cover", service: "open_cover", entityId: "cover.garage", serviceData: [:]))
        XCTAssertEqual(ServiceCall.toggle(blind, on: false),
                       ServiceCall(domain: "cover", service: "close_cover", entityId: "cover.blind", serviceData: [:]))
    }

    func testLightLevelSendsBrightnessPercent() {
        let call = ServiceCall.setLevel(light, fraction: 0.5, state: nil)
        XCTAssertEqual(call, ServiceCall(domain: "light", service: "turn_on", entityId: "light.desk",
                                         serviceData: ["brightness_pct": .number(50)]))
    }

    func testFanLevelSnapsToPercentageStep() {
        let state = EntityState(state: "on", attributes: ["percentage_step": .number(100.0 / 3.0)])
        let call = ServiceCall.setLevel(fan, fraction: 0.6, state: state)
        XCTAssertEqual(call, ServiceCall(domain: "fan", service: "set_percentage", entityId: "fan.office",
                                         serviceData: ["percentage": .number(67)]))
    }

    func testCoverLevelSetsPosition() {
        let call = ServiceCall.setLevel(garage, fraction: 0.25, state: nil)
        XCTAssertEqual(call, ServiceCall(domain: "cover", service: "set_cover_position", entityId: "cover.garage",
                                         serviceData: ["position": .number(25)]))
    }

    func testKindsWithoutASliderHaveNoLevelCall() {
        XCTAssertNil(ServiceCall.setLevel(heater, fraction: 0.5, state: nil))
        XCTAssertNil(ServiceCall.setLevel(blind, fraction: 0.5, state: nil))
        XCTAssertNil(ServiceCall.setLevel(sensor, fraction: 0.5, state: nil))
        XCTAssertNil(ServiceCall.toggle(sensor, on: true))
    }

    func testCommandPayloadMatchesTheWebSocketAPI() {
        let payload = ServiceCall.toggle(light, on: true)!.commandPayload
        XCTAssertEqual(payload["type"], .string("call_service"))
        XCTAssertEqual(payload["domain"], .string("light"))
        XCTAssertEqual(payload["service"], .string("turn_on"))
        XCTAssertEqual(payload["target"], .object(["entity_id": .string("light.desk")]))
        XCTAssertNil(payload["service_data"])   // omitted when empty

        let dimmed = ServiceCall.setLevel(light, fraction: 0.4, state: nil)!.commandPayload
        XCTAssertEqual(dimmed["service_data"], .object(["brightness_pct": .number(40)]))
    }
}
