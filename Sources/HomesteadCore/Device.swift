// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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
    /// Something you press rather than switch: a `button`/`input_button`
    /// entity, a script or scene, or a dashboard card that calls a service.
    case button

    /// Whether the row's trailing control is an on/off switch. A cover gets
    /// open/stop/close instead (a blind half-way is neither), and a thermostat
    /// a mode picker; a button is pressed, never switched.
    public var hasSwitch: Bool {
        switch self {
        case .light, .fan, .toggle, .mediaPlayer, .thermostat: return true
        case .cover, .sensor, .button: return false
        }
    }

    public var hasSlider: Bool {
        switch self {
        case .light, .fan: return true
        case .cover(let positionable): return positionable
        // A player's volume slider depends on supported_features, so the menu
        // adds it from the entity's state rather than from the kind alone; a
        // thermostat has its own target row.
        case .mediaPlayer, .thermostat, .toggle, .sensor, .button: return false
        }
    }
}

public struct Device: Equatable, Sendable {
    public let entityId: String
    public let displayName: String
    public let kind: DeviceKind
    /// The card's `mdi:` icon, for buttons.
    public let icon: String?
    /// What pressing a card button calls. Nil for an entity's own row.
    public let action: CardAction?
    /// The dashboard grid a button sits in.
    public let layout: ButtonLayout?

    public init(entityId: String, displayName: String, kind: DeviceKind,
                icon: String? = nil, action: CardAction? = nil, layout: ButtonLayout? = nil) {
        self.entityId = entityId
        self.displayName = displayName
        self.kind = kind
        self.icon = icon
        self.action = action
        self.layout = layout
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
            guard let kind = ref.action != nil ? .button : kind(for: ref.entityId, state: state) else { continue }
            if kind == .sensor && !showSensors { continue }

            let device = Device(
                entityId: ref.entityId,
                displayName: ref.nameOverride ?? state?.friendlyName ?? fallbackName(ref),
                kind: kind,
                icon: ref.icon,
                action: ref.action,
                layout: ref.layout
            )

            if let last = groups.last, last.title == ref.header {
                groups[groups.count - 1] = DeviceGroup(title: last.title, devices: last.devices + [device])
            } else {
                groups.append(DeviceGroup(title: ref.header, devices: [device]))
            }
        }

        return groups
    }

    /// A card button with neither a name nor a known entity: say what it calls.
    private static func fallbackName(_ ref: DeviceRef) -> String {
        guard let action = ref.action, ref.entityId.hasPrefix("action:") else { return ref.entityId }
        return action.service.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func kind(for entityId: String, state: EntityState?) -> DeviceKind? {
        switch String(entityId.prefix(while: { $0 != "." })) {
        case "light": return .light
        case "fan": return .fan
        case "switch", "input_boolean", "remote", "automation", "group": return .toggle
        case "button", "input_button", "script", "scene": return .button
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
