import XCTest
@testable import HomesteadCore

final class ColorTemperatureTests: XCTestCase {
    private let light = Device(entityId: "light.desk", displayName: "Desk", kind: .light)
    private let fan = Device(entityId: "fan.office", displayName: "Fan", kind: .fan)

    private func bulb(modes: [String], minK: Double? = 2000, maxK: Double? = 6500,
                      currentK: Double? = nil, mireds: (min: Double, max: Double)? = nil) -> EntityState {
        var attributes: [String: JSONValue] = [
            "supported_color_modes": .array(modes.map { .string($0) }),
        ]
        if let minK { attributes["min_color_temp_kelvin"] = .number(minK) }
        if let maxK { attributes["max_color_temp_kelvin"] = .number(maxK) }
        if let currentK { attributes["color_temp_kelvin"] = .number(currentK) }
        if let mireds {
            attributes["min_mireds"] = .number(mireds.min)
            attributes["max_mireds"] = .number(mireds.max)
        }
        return EntityState(state: "on", attributes: attributes)
    }

    func testWarmthIsOfferedOnlyWhenTheBulbSupportsIt() {
        XCTAssertTrue(LightCapabilities.supportsColorTemperature(bulb(modes: ["color_temp"])))
        XCTAssertTrue(LightCapabilities.supportsColorTemperature(bulb(modes: ["hs", "color_temp"])))
        XCTAssertFalse(LightCapabilities.supportsColorTemperature(bulb(modes: ["hs"])))
        XCTAssertFalse(LightCapabilities.supportsColorTemperature(nil))
    }

    func testRangeReadsKelvinAttributes() {
        let range = ColorTemperatureRange(state: bulb(modes: ["color_temp"], minK: 2202, maxK: 6535))
        XCTAssertEqual(range.minimumKelvin, 2202)
        XCTAssertEqual(range.maximumKelvin, 6535)
    }

    func testRangeFallsBackToMiredsWhenKelvinIsAbsent() {
        // Older integrations report mireds only; kelvin is their reciprocal, and
        // the *max* mired is the warmest, so the ends swap.
        let range = ColorTemperatureRange(state: bulb(modes: ["color_temp"], minK: nil, maxK: nil,
                                                      mireds: (min: 153, max: 500)))
        XCTAssertEqual(range.minimumKelvin, 2000, accuracy: 1)
        XCTAssertEqual(range.maximumKelvin, 6535, accuracy: 1)
    }

    func testRangeFallsBackToACommonBandWhenNothingIsReported() {
        let range = ColorTemperatureRange(state: bulb(modes: ["color_temp"], minK: nil, maxK: nil))
        XCTAssertEqual(range.minimumKelvin, 2000)
        XCTAssertEqual(range.maximumKelvin, 6500)
    }

    func testFractionRunsWarmToCool() {
        let range = ColorTemperatureRange(state: bulb(modes: ["color_temp"], minK: 2000, maxK: 6000))
        XCTAssertEqual(range.fraction(of: 2000), 0, accuracy: 0.001)
        XCTAssertEqual(range.fraction(of: 4000), 0.5, accuracy: 0.001)
        XCTAssertEqual(range.fraction(of: 6000), 1, accuracy: 0.001)
        XCTAssertEqual(range.kelvin(at: 0.25), 3000, accuracy: 1)
    }

    func testCurrentKelvinPrefersKelvinThenMireds() {
        XCTAssertEqual(ColorTemperatureRange.current(of: bulb(modes: ["color_temp"], currentK: 3200)), 3200)

        let miredOnly = EntityState(state: "on", attributes: ["color_temp": .number(250)])
        XCTAssertEqual(ColorTemperatureRange.current(of: miredOnly) ?? 0, 4000, accuracy: 1)
        XCTAssertNil(ColorTemperatureRange.current(of: EntityState(state: "on")))
    }

    func testSetWarmthBuildsAKelvinTurnOn() {
        let call = ServiceCall.setColorTemperature(light, kelvin: 3000)
        XCTAssertEqual(call, ServiceCall(domain: "light", service: "turn_on", entityId: "light.desk",
                                         serviceData: ["color_temp_kelvin": .number(3000)]))
        XCTAssertNil(ServiceCall.setColorTemperature(fan, kelvin: 3000))
    }
}
