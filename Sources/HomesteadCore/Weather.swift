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

/// What the icon shows outside: the sky, whether it is night, and a line for
/// the tooltip.
public struct WeatherReport: Equatable, Sendable {
    public let sky: Sky?
    public let night: Bool
    public let summary: String

    /// - Parameters:
    ///   - weather: a `weather.*` entity's state.
    ///   - sun: `sun.sun`, which says whether it is night. A provider's own
    ///     `clear-night` and `sunny` outrank it.
    public init?(weather: EntityState?, sun: EntityState?, unit: String) {
        guard let weather, weather.isAvailable else { return nil }
        let condition = weather.state
        sky = Self.sky(for: condition)
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

    /// Which `weather.*` entity to follow when none has been chosen: the one
    /// Home Assistant creates at onboarding (met.no's "Forecast Home"), else
    /// the first there is.
    public static func automaticEntity(from ids: [String]) -> String? {
        let weather = ids.filter { $0.hasPrefix("weather.") }.sorted()
        return weather.contains("weather.forecast_home") ? "weather.forecast_home" : weather.first
    }
}
