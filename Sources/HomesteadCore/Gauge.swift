// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// An sRGB colour, 0…1 per channel, so the colour logic can live (and be
/// tested) without AppKit.
public struct RGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    func mixed(with other: RGBColor, _ amount: Double) -> RGBColor {
        RGBColor(red: red + (other.red - red) * amount,
                 green: green + (other.green - green) * amount,
                 blue: blue + (other.blue - blue) * amount)
    }
}

/// A dashboard `gauge` card: the range it spans and the `severity` bands that
/// colour it.
public struct GaugeSpec: Equatable, Sendable {
    public let min: Double
    public let max: Double
    /// `green`, `yellow` and `red` thresholds, any of them absent.
    public let green: Double?
    public let yellow: Double?
    public let red: Double?

    /// Home Assistant's default theme colours for the gauge card's severity
    /// (`--success-color`, `--warning-color`, `--error-color`) and for a gauge
    /// with none (`--info-color`), from the frontend's `color.globals.ts`;
    /// `hui-gauge-card.ts` maps green/yellow/red/normal to them.
    public static let success = RGBColor(hex: 0x43A047)
    public static let warning = RGBColor(hex: 0xFFA600)
    public static let error = RGBColor(hex: 0xDB4437)
    public static let info = RGBColor(hex: 0x039BE5)

    public init(min: Double = 0, max: Double = 100, green: Double? = nil, yellow: Double? = nil, red: Double? = nil) {
        self.min = min
        self.max = max
        self.green = green
        self.yellow = yellow
        self.red = red
    }

    /// Reads a `gauge` card's `min`, `max` and `severity`.
    public init(card: JSONValue) {
        let severity = card["severity"]
        self.init(min: card["min"]?.double ?? 0, max: card["max"]?.double ?? 100,
                  green: severity?["green"]?.double, yellow: severity?["yellow"]?.double,
                  red: severity?["red"]?.double)
    }

    /// How full the arc is: the value's place between `min` and `max`,
    /// clamped.
    public func fraction(of value: Double) -> Double {
        guard max > min else { return 0 }
        return Swift.min(Swift.max((value - min) / (max - min), 0), 1)
    }

    /// The fill colour for a value. Each threshold is an anchor — green at
    /// `green`, yellow at `yellow`, red at `red` — and a value between two
    /// anchors blends between their colours, so a draining battery fades from
    /// green through yellow to red instead of jumping a band at a time.
    /// Beyond the outermost anchor the colour holds. Works whichever way the
    /// thresholds run (a battery's green is high, a temperature's red is).
    /// Nil when the card sets no severity: draw it in `info`.
    public func color(for value: Double) -> RGBColor? {
        let anchors = [(green, Self.success), (yellow, Self.warning), (red, Self.error)]
            .compactMap { threshold, color in threshold.map { ($0, color) } }
            .sorted { $0.0 < $1.0 }
        guard let first = anchors.first, let last = anchors.last else { return nil }
        if value <= first.0 { return first.1 }
        if value >= last.0 { return last.1 }
        for (low, high) in zip(anchors, anchors.dropFirst()) where value <= high.0 {
            let span = high.0 - low.0
            return span > 0 ? low.1.mixed(with: high.1, (value - low.0) / span) : high.1
        }
        return last.1
    }
}
