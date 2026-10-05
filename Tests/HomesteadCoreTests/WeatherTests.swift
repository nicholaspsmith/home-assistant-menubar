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

    // MARK: - Intensity

    private let now = ISO8601DateFormatter().date(from: "2026-10-05T23:20:00Z")!

    private func hour(_ time: String, chance: Double? = nil, amount: Double? = nil) -> JSONValue {
        var entry: [String: JSONValue] = ["datetime": .string(time), "condition": .string("rainy")]
        if let chance { entry["precipitation_probability"] = .number(chance) }
        if let amount { entry["precipitation"] = .number(amount) }
        return .object(entry)
    }

    private func intensity(_ condition: String, _ attributes: [String: JSONValue] = [:],
                           hourly: [JSONValue]? = nil) -> Double? {
        WeatherReport.precipitationIntensity(condition: condition, attributes: attributes, hourly: hourly, now: now)
    }

    func testIntensityPrefersThisHoursChance() {
        // NWS: a chance per hour, no amount. The hour that has begun wins.
        let hourly = [hour("2026-10-05T19:00:00-04:00", chance: 40),
                      hour("2026-10-05T20:00:00-04:00", chance: 90),
                      hour("2026-10-05T18:00:00-04:00", chance: 10)]
        XCTAssertEqual(intensity("rainy", hourly: hourly)!, 0.4, accuracy: 1e-9)
        // Chance outranks an amount, and is clamped.
        XCTAssertEqual(intensity("rainy", hourly: [hour("2026-10-05T23:00:00Z", chance: 130, amount: 0)])!, 1)
        // The entity's own chance, when the forecast has none.
        XCTAssertEqual(intensity("snowy", ["precipitation_probability": .number(25)])!, 0.25, accuracy: 1e-9)
    }

    func testIntensityFromTheAmountInItsUnit() {
        // met.no: an amount per hour in the entity's unit, no chance.
        let inches: [String: JSONValue] = ["precipitation_unit": .string("in")]
        XCTAssertEqual(intensity("rainy", inches, hourly: [hour("2026-10-05T23:00:00+00:00", amount: 0)])!, 0.15, accuracy: 1e-9)
        XCTAssertEqual(intensity("rainy", inches, hourly: [hour("2026-10-05T23:00:00+00:00", amount: 0.08)])!,
                       0.15 + 0.85 * (0.08 * 25.4 / 4), accuracy: 1e-9)
        XCTAssertEqual(intensity("pouring", inches, hourly: [hour("2026-10-05T23:00:00+00:00", amount: 1)])!, 1)
        XCTAssertEqual(intensity("rainy", ["precipitation": .number(2)])!, 0.15 + 0.85 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(intensity("rainy", ["precipitation": .number(1), "precipitation_unit": .string("cm")])!, 1)
        XCTAssertEqual(intensity("rainy", ["precipitation": .number(-3)])!, 0.15, accuracy: 1e-9)
    }

    func testIntensityFallsBackToTheCondition() {
        XCTAssertEqual(intensity("rainy"), 0.5)
        XCTAssertEqual(intensity("pouring"), 1)
        XCTAssertEqual(intensity("snowy"), 0.5)
        XCTAssertEqual(intensity("lightning-rainy"), 0.5)
        // A forecast with nothing useful in it, or no times, changes nothing.
        XCTAssertEqual(intensity("rainy", hourly: [.object(["condition": .string("rainy")])]), 0.5)
        XCTAssertEqual(intensity("rainy", hourly: [.string("junk"), hour("not a date", chance: 80)]), 0.5)
        XCTAssertEqual(intensity("rainy", ["precipitation": .string("lots")], hourly: []), 0.5)
    }

    func testNothingFallingHasNoIntensity() {
        for condition in ["sunny", "clear-night", "partlycloudy", "cloudy", "fog", "windy", "exceptional"] {
            XCTAssertNil(intensity(condition, ["precipitation_probability": .number(80)]), condition)
        }
    }

    func testTheForecastsFirstHourWhenNoneHasBegun() {
        let hourly = [hour("2026-10-06T01:00:00Z", chance: 70), hour("2026-10-06T00:00:00Z", chance: 20)]
        XCTAssertEqual(intensity("rainy", hourly: hourly)!, 0.2, accuracy: 1e-9)
        XCTAssertEqual(intensity("rainy", hourly: [hour("2026-10-05T23:00:00.000Z", chance: 60)])!, 0.6, accuracy: 1e-9)
    }

    func testTheReportCarriesTheIntensity() {
        let rain = EntityState(state: "rainy", attributes: ["precipitation_unit": .string("mm")])
        XCTAssertEqual(WeatherReport(weather: rain, sun: day, unit: "°C",
                                     hourly: [hour("2026-10-05T23:00:00Z", amount: 4)], now: now)?.intensity, 1)
        XCTAssertEqual(WeatherReport(weather: rain, sun: day, unit: "°C")?.intensity, 0.5)
        XCTAssertNil(WeatherReport(weather: weather("sunny"), sun: day, unit: "°C")?.intensity)
    }
}
