import Foundation

/// Conversions between the slider's 0…1 and the units each HA domain speaks.
public enum LevelMath {
    /// `light.brightness` is 0…255.
    public static func fraction(brightness: JSONValue?) -> Double {
        guard let raw = brightness?.double else { return 0 }
        return min(max(raw / 255, 0), 1)
    }

    /// `fan.percentage` and `cover.current_position` are already 0…100.
    public static func fraction(percentage: JSONValue?) -> Double {
        guard let raw = percentage?.double else { return 0 }
        return min(max(raw / 100, 0), 1)
    }

    /// Lights take `brightness_pct` 1…100. Zero is deliberately unreachable:
    /// `turn_on` at 0% turns the light off, which would leave the row's switch
    /// on and the light dark.
    public static func brightnessPct(from fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded()).clamped(to: 1...100)
    }

    /// Fans accept only multiples of `percentage_step`; a three-speed fan has a
    /// step of 33.33…, and an unsnapped 40% is rejected outright.
    public static func fanPercentage(from fraction: Double, step: Double?) -> Int {
        let pct = min(max(fraction, 0), 1) * 100
        guard let step, step > 0, step < 100 else { return Int(pct.rounded()).clamped(to: 0...100) }
        return Int(((pct / step).rounded() * step).rounded()).clamped(to: 0...100)
    }

    public static func coverPosition(from fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded()).clamped(to: 0...100)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
