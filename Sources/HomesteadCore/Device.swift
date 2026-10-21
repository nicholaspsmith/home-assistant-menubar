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
    /// A `lock`: its state, and one button that does the opposite.
    case lock
    /// An `input_select` or `select`: the current option, and the list of
    /// the others to choose from.
    case select
    /// A dashboard `gauge` card: the entity's value as an arc meter.
    case gauge

    /// Whether the row's trailing control is an on/off switch. A cover gets
    /// open/stop/close instead (a blind half-way is neither), and a thermostat
    /// a mode picker; a button is pressed, never switched.
    public var hasSwitch: Bool {
        switch self {
        case .light, .fan, .toggle, .mediaPlayer, .thermostat: return true
        case .cover, .sensor, .button, .lock, .select, .gauge: return false
        }
    }

    public var hasSlider: Bool {
        switch self {
        case .light, .fan: return true
        case .cover(let positionable): return positionable
        // A player's volume slider depends on supported_features, so the menu
        // adds it from the entity's state rather than from the kind alone; a
        // thermostat has its own target row.
        case .mediaPlayer, .thermostat, .toggle, .sensor, .button, .lock, .select, .gauge: return false
        }
    }
}

extension DeviceKind {
    /// Whether a slider drag sends the level as it moves, or once, when the
    /// slider is let go. A bulb or fan follows a stream of calls happily; a
    /// motorised cover does not — a burst of `set_cover_position` left a
    /// Zigbee shade's controller jittering on its own, deaf to its buttons,
    /// until it was sent a stop.
    public var sendsLevelWhileDragging: Bool {
        switch self {
        case .cover: return false
        case .light, .fan, .mediaPlayer, .thermostat, .toggle, .sensor, .button, .lock, .select, .gauge: return true
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
    /// The horizontal stack the row shares a line in, if any.
    public let stack: Int?
    /// When the row shows; see `VisibilityCondition`.
    public let visibility: [VisibilityCondition]
    /// A gauge's range and colours.
    public let gauge: GaugeSpec?

    public init(entityId: String, displayName: String, kind: DeviceKind,
                icon: String? = nil, action: CardAction? = nil, layout: ButtonLayout? = nil,
                stack: Int? = nil, visibility: [VisibilityCondition] = [], gauge: GaugeSpec? = nil) {
        self.entityId = entityId
        self.displayName = displayName
        self.kind = kind
        self.icon = icon
        self.action = action
        self.layout = layout
        self.stack = stack
        self.visibility = visibility
        self.gauge = gauge
    }

    public var domain: String { String(entityId.prefix(while: { $0 != "." })) }
}

/// A run of devices under one card/section/view title.
public struct DeviceGroup: Equatable, Sendable {
    public let title: String
    public let devices: [Device]
    /// A gauge drawn at the end of the group's heading rather than as a row
    /// of its own: a section's battery beside the section's name.
    public let headingGauge: Device?
    /// A lock drawn as a padlock on the heading: see `LockPlacement`.
    public let headingLock: Device?
    /// Whether the group's title is a heading on the dashboard (a heading
    /// card, or a card or section title) rather than the view's name.
    public let headed: Bool
    /// The dashboard view the group is on, and that view's title. Views after
    /// the first fold away under their titles.
    public let view: Int
    public let viewTitle: String

    public init(title: String, devices: [Device], headingGauge: Device? = nil, headingLock: Device? = nil,
                headed: Bool = false, view: Int = 0, viewTitle: String = "") {
        self.title = title
        self.devices = devices
        self.headingGauge = headingGauge
        self.headingLock = headingLock
        self.headed = headed
        self.view = view
        self.viewTitle = viewTitle
    }
}

public enum DeviceCatalog {
    /// HA's `CoverEntityFeature.SET_POSITION`.
    private static let coverSetPosition = 4

    public static func build(refs: [DeviceRef], states: [String: EntityState], showSensors: Bool) -> [DeviceGroup] {
        var groups: [DeviceGroup] = []

        for ref in refs {
            let state = states[ref.entityId]
            // A gauge is shown whatever Show Sensors says: the dashboard put
            // it there on purpose, as a meter rather than a reading.
            let kind: DeviceKind
            if ref.action != nil {
                kind = .button
            } else if ref.gauge != nil {
                kind = .gauge
            } else if let domainKind = self.kind(for: ref.entityId, state: state) {
                kind = domainKind
            } else {
                continue
            }
            if kind == .sensor && !showSensors { continue }

            let device = Device(
                entityId: ref.entityId,
                displayName: ref.nameOverride ?? state?.friendlyName ?? fallbackName(ref),
                kind: kind,
                icon: ref.icon,
                action: ref.action,
                layout: ref.layout,
                stack: ref.stack,
                visibility: ref.visibility,
                gauge: ref.gauge
            )

            let current: DeviceGroup
            if let last = groups.last, last.title == ref.header, last.view == ref.view {
                current = groups.removeLast()
            } else {
                current = DeviceGroup(title: ref.header, devices: [], headed: ref.headed,
                                      view: ref.view, viewTitle: ref.viewTitle)
            }
            let inHeading = GaugePlacement.inHeading(ref, groupHasGauge: current.headingGauge != nil)
            groups.append(DeviceGroup(title: current.title,
                                      devices: inHeading ? current.devices : current.devices + [device],
                                      headingGauge: inHeading ? device : current.headingGauge,
                                      headed: current.headed, view: current.view, viewTitle: current.viewTitle))
        }

        // A headed section with one lock shows it as a padlock on the heading.
        return groups.map(LockPlacement.promote)
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
        case "lock": return .lock
        case "input_select", "select": return .select
        default: return nil
        }
    }
}

/// Where a gauge goes: at the trailing end of its section's heading when it
/// has one (and no other gauge has taken that spot), otherwise as a compact
/// row of its own.
public enum GaugePlacement {
    public static func inHeading(_ ref: DeviceRef, groupHasGauge: Bool) -> Bool {
        ref.gauge != nil && ref.action == nil && ref.headed && !groupHasGauge
    }
}

/// One thing the menu draws for a stretch of a group's devices.
public enum MenuRun: Equatable, Sendable {
    /// A device on its own row (with any slider or picker rows it brings).
    case row(Device)
    /// Buttons from one dashboard grid, kept in its columns.
    case buttonGrid([Device])
    /// Rows a horizontal stack puts side by side, sharing one line.
    case line([Device])
}

public enum MenuLayout {
    /// Kinds compact enough to share a line: a name and one control, with no
    /// slider or picker rows of their own underneath (a select's options
    /// open below the line).
    public static func sharesLine(_ kind: DeviceKind) -> Bool {
        switch kind {
        case .toggle, .select, .lock, .sensor: return true
        case .light, .fan, .cover, .mediaPlayer, .thermostat, .button, .gauge: return false
        }
    }

    /// Splits a group's devices into rows, button grids and shared lines.
    ///
    /// - Parameter standalone: buttons that must be a row of their own — a
    ///   script whose Run… opens a form says so on its button.
    public static func runs(_ devices: [Device], standalone: (Device) -> Bool = { _ in false }) -> [MenuRun] {
        var runs: [MenuRun] = []
        var index = devices.startIndex
        while index < devices.endIndex {
            let device = devices[index]
            let run: [Device]
            if device.kind == .button, !standalone(device) {
                run = Array(devices[index...].prefix {
                    $0.kind == .button && $0.layout == device.layout && !standalone($0)
                })
                runs.append(run.count > 1 ? .buttonGrid(run) : .row(device))
            } else if let stack = device.stack, sharesLine(device.kind) {
                run = Array(devices[index...].prefix { $0.stack == stack && sharesLine($0.kind) })
                runs.append(run.count > 1 ? .line(run) : .row(device))
            } else {
                run = [device]
                runs.append(.row(device))
            }
            index += run.count
        }
        return runs
    }
}
