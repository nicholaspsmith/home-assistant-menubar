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

    func testThermostatsHaveASwitchAndASlider() {
        XCTAssertTrue(DeviceKind.thermostat.hasSwitch)
        XCTAssertTrue(DeviceKind.thermostat.hasSlider)
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

    func testDegenerateRangeDoesNotDivideByZero() {
        let flat = TemperatureRange(state: state("heat", current: 20, target: 20, min: 20, max: 20))
        XCTAssertEqual(flat.fraction(of: 20), 0)
        XCTAssertEqual(flat.temperature(at: 0.5), 20)
    }

    func testFractionMapsAcrossTheRange() {
        let range = TemperatureRange(state: state("heat", current: 20, target: 22, min: 10, max: 30))
        XCTAssertEqual(range.fraction(of: 10), 0, accuracy: 0.001)
        XCTAssertEqual(range.fraction(of: 20), 0.5, accuracy: 0.001)
        XCTAssertEqual(range.fraction(of: 30), 1, accuracy: 0.001)
        XCTAssertEqual(range.fraction(of: 40), 1, accuracy: 0.001)   // clamped
    }

    func testTemperatureSnapsToTheEntitysStep() {
        let range = TemperatureRange(state: state("heat", current: 20, target: 22, min: 10, max: 30, step: 0.5))
        XCTAssertEqual(range.temperature(at: 0.51), 20.0, accuracy: 0.001)
        XCTAssertEqual(range.temperature(at: 0.53), 20.5, accuracy: 0.001)

        let wholeDegrees = TemperatureRange(state: state("heat", current: 20, target: 22, min: 10, max: 30, step: 1))
        XCTAssertEqual(wholeDegrees.temperature(at: 0.53), 21, accuracy: 0.001)
    }

    // MARK: - Calls

    func testSettingATemperatureUsesTheEntitysOwnDomain() {
        let climate = ServiceCall.setLevel(thermostat, fraction: 0.5,
                                           state: state("heat", current: 20, target: 22, min: 10, max: 30))
        XCTAssertEqual(climate, ServiceCall(domain: "climate", service: "set_temperature",
                                            entityId: "climate.hallway",
                                            serviceData: ["temperature": .number(20)]))

        let water = ServiceCall.setLevel(hotTub, fraction: 1,
                                         state: state("eco", current: 38, target: 39, min: 30, max: 40))
        XCTAssertEqual(water, ServiceCall(domain: "water_heater", service: "set_temperature",
                                          entityId: "water_heater.hot_tub",
                                          serviceData: ["temperature": .number(40)]))
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

    func testTemperatureTextShowsTheReadingAndTheTarget() {
        let heating = state("heat", current: 20.5, target: 22)
        XCTAssertEqual(TemperatureRange.text(state: heating, unit: "°C"), "20.5°C → 22°C")

        // Off: the target is not being worked towards, so only the reading.
        XCTAssertEqual(TemperatureRange.text(state: state("off", current: 20.5, target: 22), unit: "°C"), "20.5°C")

        // A thermostat with no sensor of its own still shows what it is set to.
        XCTAssertEqual(TemperatureRange.text(state: state("heat", current: nil, target: 22), unit: "°F"), "→ 22°F")
        XCTAssertEqual(TemperatureRange.text(state: EntityState(state: "heat"), unit: "°C"), "")
    }

    func testTemperatureTextDropsATrailingZero() {
        XCTAssertEqual(TemperatureRange.text(state: state("heat", current: 21.0, target: 22.5), unit: "°C"),
                       "21°C → 22.5°C")
    }
}
