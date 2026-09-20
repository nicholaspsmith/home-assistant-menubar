// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// One entity's current state as the menu needs it.
public struct EntityState: Equatable, Sendable {
    public var state: String
    public var attributes: [String: JSONValue]

    public init(state: String, attributes: [String: JSONValue] = [:]) {
        self.state = state
        self.attributes = attributes
    }

    public var friendlyName: String? { attributes["friendly_name"]?.string }
    public var unit: String? { attributes["unit_of_measurement"]?.string }

    /// `unavailable` and `unknown` are HA's two "no reading" states; rows for
    /// them are shown but disabled rather than hidden, so a device that drops
    /// off the network does not silently vanish from the menu.
    public var isAvailable: Bool { state != "unavailable" && state != "unknown" }

    /// Covers report travel states, and a thermostat's state is its mode, so
    /// "on" is only one of several ways an entity says it is doing something.
    /// Treat anything but fully closed or off as on, so the row's switch
    /// reflects whether the device is working.
    public var isOn: Bool {
        switch state {
        case "on", "open", "opening", "closing": return true
        // climate hvac modes and water_heater operation modes.
        case "heat", "cool", "auto", "heat_cool", "dry", "fan_only",
             "eco", "electric", "gas", "heat_pump", "high_demand", "performance":
            return true
        // media_player states. "standby" is deliberately off: a TV in standby
        // is showing nothing and its volume cannot be set.
        case "playing", "paused", "idle", "buffering":
            return true
        default: return false
        }
    }
}
