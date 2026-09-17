import Foundation

/// What controls a row shows, derived from the entity's domain.
public enum DeviceKind: Equatable, Sendable {
    case light
    case fan
    case toggle
    /// `positionable` means the cover reports SET_POSITION, so it gets a slider.
    case cover(positionable: Bool)
    /// A `media_player`: power, volume and transport, each offered only when
    /// the entity reports it.
    case mediaPlayer
    /// A `climate` or `water_heater` entity: a reading, a target, and a band to
    /// set it in.
    case thermostat
    case sensor

    public var hasSwitch: Bool { self != .sensor }

    public var hasSlider: Bool {
        switch self {
        case .light, .fan, .thermostat: return true
        case .cover(let positionable): return positionable
        // A player's volume slider depends on supported_features, so the menu
        // adds it from the entity's state rather than from the kind alone.
        case .mediaPlayer, .toggle, .sensor: return false
        }
    }
}

public struct Device: Equatable, Sendable {
    public let entityId: String
    public let displayName: String
    public let kind: DeviceKind

    public init(entityId: String, displayName: String, kind: DeviceKind) {
        self.entityId = entityId
        self.displayName = displayName
        self.kind = kind
    }

    public var domain: String { String(entityId.prefix(while: { $0 != "." })) }
}

/// A run of devices under one card/section/view title.
public struct DeviceGroup: Equatable, Sendable {
    public let title: String
    public let devices: [Device]

    public init(title: String, devices: [Device]) {
        self.title = title
        self.devices = devices
    }
}

public enum DeviceCatalog {
    /// HA's `CoverEntityFeature.SET_POSITION`.
    private static let coverSetPosition = 4

    public static func build(refs: [DeviceRef], states: [String: EntityState], showSensors: Bool) -> [DeviceGroup] {
        var groups: [DeviceGroup] = []

        for ref in refs {
            let state = states[ref.entityId]
            guard let kind = kind(for: ref.entityId, state: state) else { continue }
            if kind == .sensor && !showSensors { continue }

            let device = Device(
                entityId: ref.entityId,
                displayName: ref.nameOverride ?? state?.friendlyName ?? ref.entityId,
                kind: kind
            )

            if let last = groups.last, last.title == ref.header {
                groups[groups.count - 1] = DeviceGroup(title: last.title, devices: last.devices + [device])
            } else {
                groups.append(DeviceGroup(title: ref.header, devices: [device]))
            }
        }

        return groups
    }

    private static func kind(for entityId: String, state: EntityState?) -> DeviceKind? {
        switch String(entityId.prefix(while: { $0 != "." })) {
        case "light": return .light
        case "fan": return .fan
        case "switch", "input_boolean", "remote": return .toggle
        case "media_player": return .mediaPlayer
        case "cover":
            let features = state?.attributes["supported_features"]?.int ?? 0
            return .cover(positionable: features & coverSetPosition != 0)
        case "climate", "water_heater": return .thermostat
        case "sensor", "binary_sensor": return .sensor
        default: return nil
        }
    }
}
