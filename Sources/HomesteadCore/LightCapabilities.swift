// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// What a particular light can actually do, read from its own state. Colour is
/// not a property of the `light` domain but of the bulb: `supported_color_modes`
/// is how Home Assistant says whether asking for a colour means anything.
public enum LightCapabilities {
    /// The modes that accept a colour. `color_temp` is deliberately not one of
    /// them — a warm/cool white is a temperature, not a colour a picker can set.
    static let colorModes: Set<String> = ["hs", "rgb", "rgbw", "rgbww", "xy"]

    public static func supportsColor(_ state: EntityState?) -> Bool {
        modes(of: state).contains { colorModes.contains($0) }
    }

    /// Whether the bulb can be moved along the warm-to-daylight white scale.
    /// Independent of `supportsColor`: plenty of bulbs do both, and each needs
    /// its own control because neither can express the other.
    public static func supportsColorTemperature(_ state: EntityState?) -> Bool {
        modes(of: state).contains("color_temp")
    }

    private static func modes(of state: EntityState?) -> [String] {
        (state?.attributes["supported_color_modes"]?.array ?? []).compactMap(\.string)
    }

    /// The light's current colour, when it has one.
    public static func currentColor(_ state: EntityState?) -> (red: Int, green: Int, blue: Int)? {
        guard let components = state?.attributes["rgb_color"]?.array, components.count == 3,
              let red = components[0].int, let green = components[1].int, let blue = components[2].int
        else { return nil }
        return (red, green, blue)
    }
}

/// The warm-to-daylight band a bulb can be set to, in kelvin.
///
/// Home Assistant reports this in kelvin on modern integrations and in mireds
/// (micro-reciprocal degrees) on older ones. Mireds run the other way — a high
/// mired value is a *warm* light — so the ends swap when converting, which is
/// the sort of thing that silently inverts a slider if it is not handled here.
public struct ColorTemperatureRange: Equatable, Sendable {
    public let minimumKelvin: Double
    public let maximumKelvin: Double

    /// A band most tunable-white bulbs cover, for one that reports no limits.
    static let fallback = (minimum: 2000.0, maximum: 6500.0)

    public init(state: EntityState?) {
        let attributes = state?.attributes ?? [:]
        if let low = attributes["min_color_temp_kelvin"]?.double,
           let high = attributes["max_color_temp_kelvin"]?.double, high > low {
            minimumKelvin = low
            maximumKelvin = high
        } else if let lowMired = attributes["min_mireds"]?.double,
                  let highMired = attributes["max_mireds"]?.double,
                  lowMired > 0, highMired > lowMired {
            minimumKelvin = Self.kelvin(fromMireds: highMired)
            maximumKelvin = Self.kelvin(fromMireds: lowMired)
        } else {
            minimumKelvin = Self.fallback.minimum
            maximumKelvin = Self.fallback.maximum
        }
    }

    /// Where a colour temperature sits in the band, 0 warm … 1 daylight.
    public func fraction(of kelvin: Double) -> Double {
        guard maximumKelvin > minimumKelvin else { return 0 }
        return min(max((kelvin - minimumKelvin) / (maximumKelvin - minimumKelvin), 0), 1)
    }

    public func kelvin(at fraction: Double) -> Double {
        guard maximumKelvin > minimumKelvin else { return minimumKelvin }
        return (minimumKelvin + min(max(fraction, 0), 1) * (maximumKelvin - minimumKelvin)).rounded()
    }

    /// The bulb's current colour temperature, whichever unit it reports in.
    public static func current(of state: EntityState?) -> Double? {
        if let kelvin = state?.attributes["color_temp_kelvin"]?.double { return kelvin }
        if let mireds = state?.attributes["color_temp"]?.double, mireds > 0 { return kelvin(fromMireds: mireds) }
        return nil
    }

    static func kelvin(fromMireds mireds: Double) -> Double {
        (1_000_000 / mireds).rounded()
    }
}
