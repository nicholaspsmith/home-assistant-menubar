// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// The temperature band a thermostat works in, and the step it moves in.
///
/// Every value comes from the entity: a hot tub's band (80–104 °F in whole
/// degrees) has nothing in common with a hallway thermostat's.
public struct TemperatureRange: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let step: Double

    /// - Parameter unit: the house's temperature unit. An entity that reports
    ///   no step moves in Home Assistant's own default for it: whole degrees
    ///   Fahrenheit, half degrees Celsius.
    public init(state: EntityState?, unit: String = "°C") {
        let fahrenheit = unit.hasSuffix("F")
        minimum = state?.attributes["min_temp"]?.double ?? (fahrenheit ? 45 : 7)
        maximum = state?.attributes["max_temp"]?.double ?? (fahrenheit ? 95 : 35)
        let fallback = fahrenheit ? 1.0 : 0.5
        let reported = state?.attributes["target_temp_step"]?.double ?? fallback
        step = reported > 0 ? reported : fallback
    }

    /// Snapped to the step — Home Assistant rejects a target that is not a
    /// multiple of it — and kept inside the band.
    public func clamp(_ temperature: Double) -> Double {
        let snapped = (temperature / step).rounded() * step
        return min(max(snapped, minimum), maximum)
    }

    /// What the entity reads right now, when it has a sensor of its own.
    public static func current(of state: EntityState?) -> Double? {
        state?.attributes["current_temperature"]?.double
    }

    /// The row's value text: what it reads now, and what it is doing about it.
    /// The target has a row of its own.
    public static func text(state: EntityState?, unit: String) -> String {
        guard let state else { return "" }
        let now = current(of: state).map { format($0) + unit }
        let action = state.isOn ? state.attributes["hvac_action"]?.string.flatMap(actionText) : nil
        return [now, action].compactMap { $0 }.joined(separator: " · ")
    }

    private static func actionText(_ action: String) -> String? {
        switch action {
        case "off": return nil
        case "fan": return "Fan"
        default: return action.prefix(1).uppercased() + action.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Whole degrees lose the decimal: "21°C", not "21.0°C".
    public static func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }
}

/// What a thermostat is set to: one target, or — in heat/cool — a band it
/// keeps the room inside.
public enum ThermostatTargets: Equatable, Sendable {
    case single(Double)
    case range(low: Double, high: Double)

    /// Which of the targets an arrow moves.
    public enum Edge: Equatable, Sendable {
        case single, low, high
    }

    public static func current(of state: EntityState?) -> ThermostatTargets? {
        guard let state else { return nil }
        let low = state.attributes["target_temp_low"]?.double
        let high = state.attributes["target_temp_high"]?.double
        let single = state.attributes["temperature"]?.double
        // A heat/cool thermostat reports its band and a null `temperature`.
        if let low, let high, single == nil || state.state == "heat_cool" {
            return .range(low: low, high: high)
        }
        return single.map { .single($0) }
    }

    public var edges: [Edge] {
        switch self {
        case .single: return [.single]
        case .range: return [.low, .high]
        }
    }

    public func value(_ edge: Edge) -> Double? {
        switch (self, edge) {
        case (.single(let value), .single): return value
        case (.range(let low, _), .low): return low
        case (.range(_, let high), .high): return high
        default: return nil
        }
    }

    /// Move one target by whole steps. The ends of a band never cross or
    /// meet: the low end stays at least a step below the high.
    public func nudged(_ edge: Edge, by steps: Int, in range: TemperatureRange) -> ThermostatTargets {
        let delta = Double(steps) * range.step
        switch (self, edge) {
        case (.single(let value), .single):
            return .single(range.clamp(value + delta))
        case (.range(let low, let high), .low):
            return .range(low: min(range.clamp(low + delta), high - range.step), high: high)
        case (.range(let low, let high), .high):
            return .range(low: low, high: max(range.clamp(high + delta), low + range.step))
        default:
            return self
        }
    }
}
