// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class WeatherTests: XCTestCase {
    private func weather(_ condition: String, temperature: Double? = 71) -> EntityState {
        var attributes: [String: JSONValue] = ["temperature_unit": .string("°F")]
        if let temperature { attributes["temperature"] = .number(temperature) }
        return EntityState(state: condition, attributes: attributes)
    }

    private let day = EntityState(state: "above_horizon")
    private let night = EntityState(state: "below_horizon")

    func testConditionsMapToSkies() {
        let cases: [(String, Sky?)] = [
            ("sunny", .clear), ("clear-night", .clear), ("partlycloudy", .partlyCloudy), ("cloudy", .cloudy),
            ("rainy", .rain), ("pouring", .heavyRain), ("lightning", .storm), ("lightning-rainy", .storm),
            ("snowy", .snow), ("snowy-rainy", .sleet), ("hail", .sleet), ("fog", .fog),
            ("windy", .wind), ("windy-variant", .wind), ("exceptional", nil),
        ]
        for (condition, sky) in cases {
            XCTAssertEqual(WeatherReport(weather: weather(condition), sun: day, unit: "°F")?.sky, sky, condition)
        }
    }

    func testNightComesFromTheSunUnlessTheProviderSays() {
        XCTAssertTrue(WeatherReport(weather: weather("cloudy"), sun: night, unit: "°F")!.night)
        XCTAssertFalse(WeatherReport(weather: weather("cloudy"), sun: day, unit: "°F")!.night)
        XCTAssertTrue(WeatherReport(weather: weather("clear-night"), sun: day, unit: "°F")!.night)
        XCTAssertFalse(WeatherReport(weather: weather("sunny"), sun: night, unit: "°F")!.night)
        XCTAssertFalse(WeatherReport(weather: weather("rainy"), sun: nil, unit: "°F")!.night)
    }

    func testSummaryIsWordsAndTemperature() {
        XCTAssertEqual(WeatherReport(weather: weather("partlycloudy"), sun: day, unit: "°C")?.summary, "Partly cloudy · 71°F")
        XCTAssertEqual(WeatherReport(weather: weather("rainy", temperature: nil), sun: day, unit: "°F")?.summary, "Rainy")
    }

    func testUnavailableWeatherIsNoWeather() {
        XCTAssertNil(WeatherReport(weather: EntityState(state: "unavailable"), sun: day, unit: "°F"))
        XCTAssertNil(WeatherReport(weather: nil, sun: day, unit: "°F"))
    }

    func testAutomaticEntityPrefersForecastHome() {
        XCTAssertEqual(WeatherReport.automaticEntity(from: ["weather.nws_kchs", "light.a", "weather.forecast_home"]),
                       "weather.forecast_home")
        XCTAssertEqual(WeatherReport.automaticEntity(from: ["weather.nws_kchs", "weather.ambient"]), "weather.ambient")
        XCTAssertNil(WeatherReport.automaticEntity(from: ["light.a"]))
    }
}
