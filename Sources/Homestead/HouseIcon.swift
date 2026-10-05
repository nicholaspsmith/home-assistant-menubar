// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore
import StatusItemKit

/// Chooses the status glyph for a snapshot: the house mascot, with the weather
/// outside it, or the plain dot if Icon ▸ Dot is selected.
enum HouseIcon {
    /// - Parameter door: progress through Gertie's once-a-minute welcome, 0 … 1
    ///   (0 is the door shut, as always).
    static func image(snapshot: Snapshot, appearance: MeterAppearance, door: CGFloat = 0) -> NSImage {
        let configured = snapshot.connection != .unconfigured
        let reachable = snapshot.connection == .connected

        guard appearance.style == .character else {
            return MeterIcon.image(style: appearance.style,
                                   fraction: reachable ? 1 : 0,
                                   color: color(for: snapshot))
        }
        return CharacterIcon.house(
            lightsOn: snapshot.lightsOn,
            fanOn: snapshot.anyFanOn,
            reachable: reachable,
            configured: configured,
            weather: reachable ? snapshot.weather?.sky.map(houseWeather) : nil,
            night: snapshot.weather?.night ?? false,
            door: door
        )
    }

    /// Whether Gertie opens her door this minute: the house icon, and a house
    /// that is answering. A hollow one has nobody home to open it.
    static func welcomes(snapshot: Snapshot, appearance: MeterAppearance) -> Bool {
        appearance.style == .character && snapshot.connection == .connected
    }

    /// The tooltip: what it is like outside, when the icon is showing it.
    static func toolTip(snapshot: Snapshot) -> String? {
        snapshot.connection == .connected ? snapshot.weather?.summary : nil
    }

    private static func houseWeather(_ sky: Sky) -> HouseWeather {
        switch sky {
        case .clear: return .clear
        case .partlyCloudy: return .partlyCloudy
        case .cloudy: return .cloudy
        case .rain: return .rain
        case .heavyRain: return .heavyRain
        case .storm: return .storm
        case .snow: return .snow
        case .sleet: return .sleet
        case .fog: return .fog
        case .wind: return .wind
        }
    }

    private static func color(for snapshot: Snapshot) -> NSColor {
        switch snapshot.connection {
        case .connected: return .systemGreen
        case .connecting: return .systemOrange
        case .unreachable, .authFailed: return .systemRed
        case .unconfigured: return .systemGray
        }
    }
}
