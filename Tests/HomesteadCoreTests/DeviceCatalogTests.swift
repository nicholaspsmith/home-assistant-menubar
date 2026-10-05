// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class DeviceCatalogTests: XCTestCase {
    private let refs = [
        DeviceRef(entityId: "light.ceiling", nameOverride: nil, header: "Living Room"),
        DeviceRef(entityId: "fan.ceiling", nameOverride: "Fan", header: "Living Room"),
        DeviceRef(entityId: "switch.heater", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "input_boolean.guest", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "cover.garage", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "cover.blind", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "sensor.temperature", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "media_player.tv", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "automation.sunset", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "todo.household", nameOverride: nil, header: "Office"),
    ]

    private let states: [String: EntityState] = [
        "light.ceiling": EntityState(state: "on", attributes: ["friendly_name": .string("Ceiling Lights")]),
        "fan.ceiling": EntityState(state: "on", attributes: ["friendly_name": .string("Ceiling Fan")]),
        "switch.heater": EntityState(state: "off", attributes: ["friendly_name": .string("Space Heater")]),
        "input_boolean.guest": EntityState(state: "off"),
        "cover.garage": EntityState(state: "closed", attributes: ["supported_features": .number(15)]),
        "cover.blind": EntityState(state: "closed", attributes: ["supported_features": .number(3)]),
        "sensor.temperature": EntityState(state: "21.5", attributes: ["unit_of_measurement": .string("°C")]),
        "media_player.tv": EntityState(state: "playing"),
        "automation.sunset": EntityState(state: "on"),
        "todo.household": EntityState(state: "17"),
    ]

    func testGroupsPreserveDashboardOrderAndHeaders() {
        let groups = DeviceCatalog.build(refs: refs, states: states, showSensors: false)

        XCTAssertEqual(groups.map(\.title), ["Living Room", "Office"])
        XCTAssertEqual(groups[0].devices.map(\.entityId), ["light.ceiling", "fan.ceiling"])
        XCTAssertEqual(groups[1].devices.map(\.entityId),
                       ["switch.heater", "input_boolean.guest", "cover.garage", "cover.blind", "media_player.tv",
                        "automation.sunset"])
    }

    func testKindsComeFromTheDomain() {
        let devices = DeviceCatalog.build(refs: refs, states: states, showSensors: false).flatMap(\.devices)
        let byId = Dictionary(uniqueKeysWithValues: devices.map { ($0.entityId, $0.kind) })

        XCTAssertEqual(byId["light.ceiling"], .light)
        XCTAssertEqual(byId["fan.ceiling"], .fan)
        XCTAssertEqual(byId["switch.heater"], .toggle)
        XCTAssertEqual(byId["input_boolean.guest"], .toggle)
        XCTAssertEqual(byId["cover.garage"], .cover(positionable: true))    // supported_features 15 has SET_POSITION
        XCTAssertEqual(byId["cover.blind"], .cover(positionable: false))    // 3 is open+close only
    }

    func testDomainsWithNothingToControlAreDropped() {
        // A to-do list has nothing a menu row could switch or set.
        let ids = DeviceCatalog.build(refs: refs, states: states, showSensors: true).flatMap(\.devices).map(\.entityId)
        XCTAssertFalse(ids.contains("todo.household"))
        XCTAssertTrue(ids.contains("media_player.tv"))
    }

    func testAutomationsAndGroupsSwitchAndButtonsPress() {
        let refs = ["automation.sunset", "group.living_room", "button.restart", "input_button.doorbell",
                    "script.movie_night", "scene.evening"]
            .map { DeviceRef(entityId: $0, nameOverride: nil, header: "Home") }
        let devices = DeviceCatalog.build(refs: refs, states: [:], showSensors: false).flatMap(\.devices)
        XCTAssertEqual(devices.map(\.kind), [.toggle, .toggle, .button, .button, .button, .button])

        // A group has no turn_on of its own.
        XCTAssertEqual(ServiceCall.toggle(devices[1], on: true),
                       ServiceCall(domain: "homeassistant", service: "turn_on", entityId: "group.living_room", serviceData: [:]))
        XCTAssertEqual(ServiceCall.press(devices[2]),
                       ServiceCall(domain: "button", service: "press", entityId: "button.restart", serviceData: [:]))
        XCTAssertEqual(ServiceCall.press(devices[4]),
                       ServiceCall(domain: "script", service: "turn_on", entityId: "script.movie_night", serviceData: [:]))
    }

    func testSensorsAppearOnlyWhenEnabled() {
        let without = DeviceCatalog.build(refs: refs, states: states, showSensors: false).flatMap(\.devices)
        XCTAssertFalse(without.contains { $0.kind == .sensor })

        let with = DeviceCatalog.build(refs: refs, states: states, showSensors: true).flatMap(\.devices)
        XCTAssertEqual(with.first { $0.kind == .sensor }?.entityId, "sensor.temperature")
    }

    func testDisplayNamePrefersOverrideThenFriendlyNameThenEntityId() {
        let devices = DeviceCatalog.build(refs: refs, states: states, showSensors: false).flatMap(\.devices)
        let byId = Dictionary(uniqueKeysWithValues: devices.map { ($0.entityId, $0.displayName) })

        XCTAssertEqual(byId["fan.ceiling"], "Fan")                   // card override wins
        XCTAssertEqual(byId["light.ceiling"], "Ceiling Lights")      // friendly_name
        XCTAssertEqual(byId["input_boolean.guest"], "input_boolean.guest")
    }

    func testEntitiesWithNoStateYetStillGetRows() {
        let groups = DeviceCatalog.build(
            refs: [DeviceRef(entityId: "light.new", nameOverride: nil, header: "Hall")],
            states: [:],
            showSensors: false
        )
        XCTAssertEqual(groups.first?.devices.first?.kind, .light)
    }
}
