import Foundation

/// What a particular light can actually do, read from its own state. Colour is
/// not a property of the `light` domain but of the bulb: `supported_color_modes`
/// is how Home Assistant says whether asking for a colour means anything.
public enum LightCapabilities {
    /// The modes that accept a colour. `color_temp` is deliberately not one of
    /// them — a warm/cool white is a temperature, not a colour a picker can set.
    static let colorModes: Set<String> = ["hs", "rgb", "rgbw", "rgbww", "xy"]

    public static func supportsColor(_ state: EntityState?) -> Bool {
        guard let modes = state?.attributes["supported_color_modes"]?.array else { return false }
        return modes.contains { $0.string.map(colorModes.contains) ?? false }
    }

    /// The light's current colour, when it has one.
    public static func currentColor(_ state: EntityState?) -> (red: Int, green: Int, blue: Int)? {
        guard let components = state?.attributes["rgb_color"]?.array, components.count == 3,
              let red = components[0].int, let green = components[1].int, let blue = components[2].int
        else { return nil }
        return (red, green, blue)
    }
}
