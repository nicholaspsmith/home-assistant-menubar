// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class ThermostatTests: XCTestCase {
    private let thermostat = Device(entityId: "climate.hallway", displayName: "Hallway", kind: .thermostat)
    private let hotTub = Device(entityId: "water_heater.hot_tub", displayName: "Hot Tub", kind: .thermostat)

    private func state(_ mode: String, current: Double?, target: Double?,
                       min: Double = 7, max: Double = 35, step: Double? = 0.5) -> EntityState {
        var attributes: [String: JSONValue] = ["min_temp": .number(min), "max_temp": .number(max)]
        if let current { attributes["current_temperature"] = .number(current) }
        if let target { attributes["temperature"] = .number(target) }
        if let step { attributes["target_temp_step"] = .number(step) }
        return EntityState(state: mode, attributes: attributes)
    }

    // MARK: - Kinds

    func testClimateAndWaterHeaterAreThermostats() {
        let refs = [
            DeviceRef(entityId: "climate.hallway", nameOverride: nil, header: "Hall"),
            DeviceRef(entityId: "water_heater.hot_tub", nameOverride: nil, header: "Hall"),
        ]
        let kinds = DeviceCatalog.build(refs: refs, states: [:], showSensors: false).flatMap(\.devices).map(\.kind)
        XCTAssertEqual(kinds, [.thermostat, .thermostat])
    }

    func testThermostatsHaveASwitchButNoSlider() {
        // The target has a row of its own with steppers; a slider across
        // 50–90 °F was too coarse to land on a degree.
        XCTAssertTrue(DeviceKind.thermostat.hasSwitch)
        XCTAssertFalse(DeviceKind.thermostat.hasSlider)
    }

    func testHeatingModesCountAsOnAndOffDoesNot() {
        XCTAssertTrue(state("heat", current: 20, target: 22).isOn)
        XCTAssertTrue(state("heat_cool", current: 20, target: 22).isOn)
        XCTAssertTrue(state("eco", current: 38, target: 40).isOn)      // water_heater operation mode
        XCTAssertFalse(state("off", current: 20, target: 22).isOn)
    }

    // MARK: - The range

    func testRangeComesFromTheEntityWithSaneFallbacks() {
        let range = TemperatureRange(state: state("heat", current: 20, target: 22, min: 10, max: 30, step: 0.5))
        XCTAssertEqual(range.minimum, 10)
        XCTAssertEqual(range.maximum, 30)
        XCTAssertEqual(range.step, 0.5)

        let bare = TemperatureRange(state: EntityState(state: "heat"))
        XCTAssertEqual(bare.minimum, 7)
        XCTAssertEqual(bare.maximum, 35)
        XCTAssertEqual(bare.step, 0.5)
    }

    func testFahrenheitDefaultsToWholeDegrees() {
        // climate.hallway reports no target_temp_step; HA's own card moves it
        // a degree at a time in °F.
        let range = TemperatureRange(state: state("heat", current: 68, target: 68, min: 50, max: 90, step: nil), unit: "°F")
        XCTAssertEqual(range.step, 1)
    }

    func testClampSnapsToTheStepAndStaysInTheBand() {
        let range = TemperatureRange(state: state("heat", current: 20, target: 22, min: 10, max: 30, step: 0.5))
        XCTAssertEqual(range.clamp(20.3), 20.5)
        XCTAssertEqual(range.clamp(40), 30)
        XCTAssertEqual(range.clamp(-3), 10)
    }

    // MARK: - Targets

    private func band(low: Double, high: Double) -> EntityState {
        EntityState(state: "heat_cool", attributes: [
            "temperature": .null, "target_temp_low": .number(low), "target_temp_high": .number(high),
            "min_temp": .number(50), "max_temp": .number(90),
        ])
    }

    func testTargetsReadOneTemperatureOrAHeatCoolBand() {
        XCTAssertEqual(ThermostatTargets.current(of: state("heat", current: 20, target: 22)), .single(22))
        XCTAssertEqual(ThermostatTargets.current(of: band(low: 65, high: 68)), .range(low: 65, high: 68))
        XCTAssertNil(ThermostatTargets.current(of: EntityState(state: "off")))
        XCTAssertEqual(ThermostatTargets.range(low: 65, high: 68).edges, [.low, .high])
    }

    func testNudgingMovesOneStepAndClamps() {
        let range = TemperatureRange(state: state("heat", current: 96, target: 96, min: 80, max: 104, step: 1), unit: "°F")
        XCTAssertEqual(ThermostatTargets.single(96).nudged(.single, by: 1, in: range), .single(97))
        XCTAssertEqual(ThermostatTargets.single(104).nudged(.single, by: 1, in: range), .single(104))
    }

    func testBandEndsNeverCross() {
        let range = TemperatureRange(state: band(low: 65, high: 68), unit: "°F")
        let targets = ThermostatTargets.range(low: 66, high: 68)
        XCTAssertEqual(targets.nudged(.low, by: 1, in: range), .range(low: 67, high: 68))
        XCTAssertEqual(targets.nudged(.low, by: 3, in: range), .range(low: 67, high: 68))
        XCTAssertEqual(targets.nudged(.high, by: -5, in: range), .range(low: 66, high: 67))
        XCTAssertEqual(targets.nudged(.high, by: 1, in: range), .range(low: 66, high: 69))
    }

    // MARK: - Calls

    func testSettingTargetsUsesTheEntitysOwnDomain() {
        XCTAssertEqual(ServiceCall.setTargets(thermostat, .range(low: 65, high: 68)),
                       ServiceCall(domain: "climate", service: "set_temperature", entityId: "climate.hallway",
                                   serviceData: ["target_temp_low": .number(65), "target_temp_high": .number(68)]))
        XCTAssertEqual(ServiceCall.setTargets(hotTub, .single(39)),
                       ServiceCall(domain: "water_heater", service: "set_temperature", entityId: "water_heater.hot_tub",
                                   serviceData: ["temperature": .number(39)]))
    }

    func testModeIsSetOnClimateOnly() {
        XCTAssertEqual(ServiceCall.setHVACMode(thermostat, "cool"),
                       ServiceCall(domain: "climate", service: "set_hvac_mode", entityId: "climate.hallway",
                                   serviceData: ["hvac_mode": .string("cool")]))
        XCTAssertNil(ServiceCall.setHVACMode(hotTub, "heat"))
    }

    func testThermostatsToggleWithTheirOwnDomain() {
        XCTAssertEqual(ServiceCall.toggle(thermostat, on: false),
                       ServiceCall(domain: "climate", service: "turn_off",
                                   entityId: "climate.hallway", serviceData: [:]))
        XCTAssertEqual(ServiceCall.toggle(hotTub, on: true),
                       ServiceCall(domain: "water_heater", service: "turn_on",
                                   entityId: "water_heater.hot_tub", serviceData: [:]))
    }

    // MARK: - Reading

    func testTemperatureTextShowsTheReadingAndWhatItIsDoing() {
        var cooling = band(low: 65, high: 68)
        cooling.attributes["current_temperature"] = .number(68)
        cooling.attributes["hvac_action"] = .string("cooling")
        XCTAssertEqual(TemperatureRange.text(state: cooling, unit: "°F"), "68°F · Cooling")

        // Off: nothing is happening, so only the reading.
        XCTAssertEqual(TemperatureRange.text(state: state("off", current: 20.5, target: 22), unit: "°C"), "20.5°C")
        XCTAssertEqual(TemperatureRange.text(state: EntityState(state: "heat"), unit: "°C"), "")
    }

    func testTemperatureFormatDropsATrailingZero() {
        XCTAssertEqual(TemperatureRange.format(21.0), "21")
        XCTAssertEqual(TemperatureRange.format(22.5), "22.5")
    }
}
