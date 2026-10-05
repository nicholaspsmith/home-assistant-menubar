// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// The weather the house glyph draws, reduced from Home Assistant's fifteen
/// conditions to what can be told apart at 22pt.
public enum Sky: Equatable, Sendable {
    case clear, partlyCloudy, cloudy, rain, heavyRain, storm, snow, sleet, fog, wind
}

/// What the icon shows outside: the sky, whether it is night, how hard it is
/// coming down, and a line for the tooltip.
public struct WeatherReport: Equatable, Sendable {
    public let sky: Sky?
    public let night: Bool
    public let summary: String
    /// How hard it is raining or snowing, 0 (a drizzle) … 1 (a downpour); nil
    /// when nothing is falling.
    public let intensity: Double?

    /// - Parameters:
    ///   - weather: a `weather.*` entity's state.
    ///   - sun: `sun.sun`, which says whether it is night. A provider's own
    ///     `clear-night` and `sunny` outrank it.
    ///   - hourly: the entity's hourly forecast, from `weather/subscribe_forecast`,
    ///     if it has one: where the precipitation comes from.
    ///   - now: picks the forecast's current hour.
    public init?(weather: EntityState?, sun: EntityState?, unit: String,
                 hourly: [JSONValue]? = nil, now: Date = Date()) {
        guard let weather, weather.isAvailable else { return nil }
        let condition = weather.state
        sky = Self.sky(for: condition)
        intensity = Self.precipitationIntensity(condition: condition, attributes: weather.attributes,
                                                hourly: hourly, now: now)
        switch condition {
        case "clear-night": night = true
        case "sunny": night = false
        default: night = sun?.state == "below_horizon"
        }
        let words = Self.words(for: condition)
        let temperature = weather.attributes["temperature"]?.double.map {
            TemperatureRange.format($0) + (weather.attributes["temperature_unit"]?.string ?? unit)
        }
        summary = [words, temperature].compactMap { $0 }.joined(separator: " · ")
    }

    static func sky(for condition: String) -> Sky? {
        switch condition {
        case "sunny", "clear-night": return .clear
        case "partlycloudy": return .partlyCloudy
        case "cloudy": return .cloudy
        case "rainy": return .rain
        case "pouring": return .heavyRain
        case "lightning", "lightning-rainy": return .storm
        case "snowy": return .snow
        case "snowy-rainy", "hail": return .sleet
        case "fog": return .fog
        case "windy", "windy-variant": return .wind
        // "exceptional" covers anything from a heatwave to a tornado; an
        // empty sky is more honest than guessing which.
        default: return nil
        }
    }

    static func words(for condition: String) -> String {
        switch condition {
        case "clear-night": return "Clear"
        case "partlycloudy": return "Partly cloudy"
        case "lightning": return "Thunderstorms"
        case "lightning-rainy": return "Thunderstorms and rain"
        case "snowy-rainy": return "Sleet"
        case "windy-variant": return "Windy and cloudy"
        default:
            let text = condition.replacingOccurrences(of: "-", with: " ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    /// How hard it is coming down, 0 … 1, for a condition where something
    /// falls (nil otherwise). Providers differ in what they say, so this takes
    /// the first of:
    ///
    /// 1. the chance of precipitation this hour, 0–100 % → 0 … 1 — from the
    ///    hourly forecast, else the entity's own `precipitation_probability`
    ///    (NWS gives this and no amount);
    /// 2. the amount this hour in `precipitation_unit` (mm, cm or in), from a
    ///    trace (0.15) up to 4 mm or more (1) — from the hourly forecast, else
    ///    the entity's `precipitation` (met.no gives this and no chance);
    /// 3. the condition alone: pouring 1, any other rain or snow 0.5.
    public static func precipitationIntensity(condition: String, attributes: [String: JSONValue],
                                              hourly: [JSONValue]?, now: Date) -> Double? {
        let fallback: Double
        switch condition {
        case "pouring": fallback = 1
        case "rainy", "snowy", "snowy-rainy", "hail", "lightning-rainy": fallback = 0.5
        case "lightning": fallback = 0.3
        default: return nil
        }
        let hour = currentHour(of: hourly ?? [], now: now)

        if let chance = hour?["precipitation_probability"]?.double ?? attributes["precipitation_probability"]?.double,
           chance.isFinite {
            return min(max(chance / 100, 0), 1)
        }
        if let amount = hour?["precipitation"]?.double ?? attributes["precipitation"]?.double, amount.isFinite {
            let millimetres: Double
            switch attributes["precipitation_unit"]?.string?.lowercased() {
            case "in": millimetres = amount * 25.4
            case "cm": millimetres = amount * 10
            default: millimetres = amount
            }
            return 0.15 + 0.85 * min(max(millimetres / 4, 0), 1)
        }
        return fallback
    }

    /// The forecast entry covering `now`: the latest that has begun, or the
    /// first if none has yet. Entries without a readable time are skipped.
    static func currentHour(of forecast: [JSONValue], now: Date) -> JSONValue? {
        let timed = forecast.compactMap { entry -> (Date, JSONValue)? in
            guard let text = entry["datetime"]?.string, let date = parseDate(text) else { return nil }
            return (date, entry)
        }.sorted { $0.0 < $1.0 }
        return (timed.last { $0.0 <= now } ?? timed.first)?.1
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Which `weather.*` entity to follow when none has been chosen: the one
    /// Home Assistant creates at onboarding (met.no's "Forecast Home"), else
    /// the first there is.
    public static func automaticEntity(from ids: [String]) -> String? {
        let weather = ids.filter { $0.hasPrefix("weather.") }.sorted()
        return weather.contains("weather.forecast_home") ? "weather.forecast_home" : weather.first
    }
}
