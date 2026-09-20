// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// The temperature band a thermostat works in, and the arithmetic for driving
/// it from a 0…1 slider.
///
/// Every value comes from the entity: a hot tub's band (30–40 °C in half
/// degrees) has nothing in common with a hallway thermostat's, and a slider
/// spanning some invented range would make most of its travel useless.
public struct TemperatureRange: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let step: Double

    public init(state: EntityState?) {
        minimum = state?.attributes["min_temp"]?.double ?? 7
        maximum = state?.attributes["max_temp"]?.double ?? 35
        let reported = state?.attributes["target_temp_step"]?.double
        step = (reported ?? 0.5) > 0 ? (reported ?? 0.5) : 0.5
    }

    /// Where a temperature sits in the band, 0…1.
    public func fraction(of temperature: Double) -> Double {
        guard maximum > minimum else { return 0 }
        return min(max((temperature - minimum) / (maximum - minimum), 0), 1)
    }

    /// The temperature a slider position means, snapped to the entity's step —
    /// Home Assistant rejects a target that is not a multiple of it.
    public func temperature(at fraction: Double) -> Double {
        guard maximum > minimum else { return minimum }
        let raw = minimum + min(max(fraction, 0), 1) * (maximum - minimum)
        let snapped = (raw / step).rounded() * step
        return min(max(snapped, minimum), maximum)
    }

    /// The target the entity is currently set to.
    public static func target(of state: EntityState?) -> Double? {
        state?.attributes["temperature"]?.double
    }

    /// What the entity reads right now, when it has a sensor of its own.
    public static func current(of state: EntityState?) -> Double? {
        state?.attributes["current_temperature"]?.double
    }

    /// The row's value text: what it reads now, and what it is working towards.
    /// A thermostat that is off shows only the reading — its target is not
    /// something anything is currently trying to reach.
    public static func text(state: EntityState?, unit: String) -> String {
        guard let state else { return "" }
        let now = current(of: state).map { format($0) + unit }
        let target = state.isOn ? target(of: state).map { "→ " + format($0) + unit } : nil
        return [now, target].compactMap { $0 }.joined(separator: " ")
    }

    /// Whole degrees lose the decimal: "21°C", not "21.0°C".
    public static func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }
}
