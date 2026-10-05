// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// A sensor's reading the way the dashboard words it, not the raw state:
/// a drive's health is "OK", not "off"; a backup was "6 h ago", not an ISO
/// timestamp.
public enum SensorText {
    public static func text(_ state: EntityState, now: Date = Date()) -> String {
        let deviceClass = state.attributes["device_class"]?.string

        if state.state == "on" || state.state == "off" {
            return binary(on: state.state == "on", deviceClass: deviceClass)
        }
        if deviceClass == "timestamp", let date = parseDate(state.state) {
            return relative(date, now: now)
        }
        if let number = Double(state.state) {
            if deviceClass == "duration", let seconds = seconds(number, unit: state.unit) {
                return duration(seconds)
            }
            return trimmed(number) + (state.unit.map { $0 == "%" ? $0 : " " + $0 } ?? "")
        }
        // An enum sensor's options are identifiers: "create_backup".
        let words = state.state.replacingOccurrences(of: "_", with: " ")
        let text = words.prefix(1).uppercased() + words.dropFirst()
        return text + (state.unit.map { " " + $0 } ?? "")
    }

    /// Home Assistant's own wording for each binary_sensor device class.
    static func binary(on: Bool, deviceClass: String?) -> String {
        let pair: (String, String)
        switch deviceClass {
        case "problem": pair = ("Problem", "OK")
        case "safety": pair = ("Unsafe", "Safe")
        case "connectivity": pair = ("Connected", "Disconnected")
        case "door", "garage_door", "opening", "window": pair = ("Open", "Closed")
        case "lock": pair = ("Unlocked", "Locked")
        case "moisture": pair = ("Wet", "Dry")
        case "motion", "moving", "occupancy", "presence", "sound", "vibration", "gas", "smoke", "carbon_monoxide", "tamper":
            pair = ("Detected", "Clear")
        case "running": pair = ("Running", "Not running")
        case "battery": pair = ("Low", "Normal")
        case "battery_charging": pair = ("Charging", "Not charging")
        case "plug": pair = ("Plugged in", "Unplugged")
        case "update": pair = ("Update available", "Up to date")
        default: pair = ("On", "Off")
        }
        return on ? pair.0 : pair.1
    }

    /// "170.0" reads as "170"; long tails ("30.97") stay as the sensor gave them.
    static func trimmed(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int(number)) }
        return String(format: "%g", number)
    }

    static func relative(_ date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        guard abs(delta) >= 60 else { return "Now" }
        let amount = compact(abs(delta))
        return delta < 0 ? "\(amount) ago" : "in \(amount)"
    }

    static func duration(_ seconds: Double) -> String { compact(seconds) }

    /// The largest unit that fits: "45 s", "12 min", "6 h", "14 d".
    private static func compact(_ seconds: Double) -> String {
        switch seconds {
        case ..<60: return "\(Int(seconds)) s"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86400: return "\(Int(seconds / 3600)) h"
        default: return "\(Int(seconds / 86400)) d"
        }
    }

    private static func seconds(_ value: Double, unit: String?) -> Double? {
        switch unit {
        case "s": return value
        case "min": return value * 60
        case "h": return value * 3600
        case "d": return value * 86400
        case "ms": return value / 1000
        default: return nil
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
