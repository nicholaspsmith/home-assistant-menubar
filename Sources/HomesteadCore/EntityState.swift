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

    /// Covers report travel states; treat anything but fully closed as open, so
    /// the switch reflects where the cover is heading.
    public var isOn: Bool {
        switch state {
        case "on", "open", "opening", "closing": return true
        default: return false
        }
    }
}
