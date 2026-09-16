import XCTest
@testable import HomesteadCore

final class LightColorTests: XCTestCase {
    private let light = Device(entityId: "light.desk", displayName: "Desk", kind: .light)
    private let fan = Device(entityId: "fan.office", displayName: "Fan", kind: .fan)

    func testColourCapabilityComesFromSupportedColorModes() {
        let colour = EntityState(state: "on", attributes: ["supported_color_modes": .array([.string("hs")])])
        let rgbww = EntityState(state: "on", attributes: ["supported_color_modes": .array([.string("rgbww")])])
        let temperatureOnly = EntityState(state: "on", attributes: ["supported_color_modes": .array([.string("color_temp")])])
        let dimmerOnly = EntityState(state: "on", attributes: ["supported_color_modes": .array([.string("brightness")])])

        XCTAssertTrue(LightCapabilities.supportsColor(colour))
        XCTAssertTrue(LightCapabilities.supportsColor(rgbww))
        XCTAssertFalse(LightCapabilities.supportsColor(temperatureOnly))
        XCTAssertFalse(LightCapabilities.supportsColor(dimmerOnly))
        XCTAssertFalse(LightCapabilities.supportsColor(nil))
    }

    func testCurrentColourIsReadFromRGB() {
        let state = EntityState(state: "on", attributes: ["rgb_color": .array([.number(255), .number(128), .number(0)])])
        let rgb = LightCapabilities.currentColor(state)
        XCTAssertEqual(rgb?.red, 255)
        XCTAssertEqual(rgb?.green, 128)
        XCTAssertEqual(rgb?.blue, 0)
    }

    func testCurrentColourIsNilWhenTheLightHasNone() {
        XCTAssertNil(LightCapabilities.currentColor(EntityState(state: "on")))
        XCTAssertNil(LightCapabilities.currentColor(EntityState(state: "on", attributes: ["rgb_color": .array([.number(1)])])))
    }

    func testSetColorBuildsARGBTurnOn() {
        let call = ServiceCall.setColor(light, red: 255, green: 128, blue: 0)
        XCTAssertEqual(call, ServiceCall(domain: "light", service: "turn_on", entityId: "light.desk",
                                         serviceData: ["rgb_color": .array([.number(255), .number(128), .number(0)])]))
    }

    func testSetColorClampsToTheByteRange() {
        let call = ServiceCall.setColor(light, red: -5, green: 300, blue: 12)
        XCTAssertEqual(call?.serviceData["rgb_color"], .array([.number(0), .number(255), .number(12)]))
    }

    func testOnlyLightsTakeAColour() {
        XCTAssertNil(ServiceCall.setColor(fan, red: 1, green: 2, blue: 3))
    }
}
