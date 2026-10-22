// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// What a lock's row says and what its one button does. A lock is not a
/// switch: a lock part-way through moving has no honest on/off. Both Lock and
/// Unlock act on the first press, as the dashboard's own lock controls do.
public enum LockControl {
    public enum Action: Equatable, Sendable {
        case lock, unlock

        public var service: String {
            switch self {
            case .lock: return "lock"
            case .unlock: return "unlock"
            }
        }

        /// The button's title.
        public var title: String {
            switch self {
            case .lock: return "Lock"
            case .unlock: return "Unlock"
            }
        }
    }

    /// The state worded the way Home Assistant shows it.
    public static func text(_ state: EntityState?) -> String {
        guard let state else { return "" }
        switch state.state {
        case "locked": return "Locked"
        case "unlocked": return "Unlocked"
        case "locking": return "Locking"
        case "unlocking": return "Unlocking"
        case "jammed": return "Jammed"
        case "open": return "Open"
        case "opening": return "Opening"
        case "unavailable": return "Unavailable"
        case "unknown": return "Unknown"
        default: return state.state.prefix(1).uppercased() + state.state.dropFirst()
        }
    }

    /// The opposite of where the lock is, or is heading: a locked (or
    /// locking) door offers Unlock, anything else — unlocked, open, jammed,
    /// unknown — offers Lock.
    public static func action(for state: EntityState?) -> Action {
        switch state?.state {
        case "locked"?, "locking"?: return .unlock
        default: return .lock
        }
    }

    /// Off while the lock is moving (the press would race the motor) or gone.
    /// A jammed or unknown lock can still be told to lock: that is how you
    /// retry.
    public static func isEnabled(_ state: EntityState?) -> Bool {
        switch state?.state {
        case nil, "unavailable"?, "locking"?, "unlocking"?, "opening"?: return false
        default: return true
        }
    }
}

/// An `input_select` or `select` entity's choices.
public enum SelectOptions {
    public static func options(of state: EntityState?) -> [String] {
        state?.attributes["options"]?.array?.compactMap(\.string) ?? []
    }

    /// Whether the list can be opened: the entity is there and has options.
    /// `unknown` still can — a scene select that has never been set reports
    /// it, and choosing is how it stops.
    public static func canChoose(_ state: EntityState?) -> Bool {
        guard let state, state.state != "unavailable" else { return false }
        return !options(of: state).isEmpty
    }
}

/// A lock drawn as a padlock on its section's heading — a section that is one
/// door: its name, its lock, its battery.
public struct LockIcon: Equatable, Sendable {
    /// An SF Symbol name.
    public let symbol: String
    public let color: RGBColor
    public let isEnabled: Bool
    /// What a click does.
    public let action: LockControl.Action
    /// The tooltip and accessibility label: the state, and what a click does.
    public let label: String

    /// Home Assistant's lock state colours, exactly as its frontend's
    /// `color.globals.ts` defines them: `--state-lock-locked-color` is
    /// `--green-color`; `-unlocked-`, `-open-` and `-jammed-color` are
    /// `--red-color`; `-locking-`, `-unlocking-` and `-opening-color` are
    /// `--orange-color`; and an unavailable entity is
    /// `--state-unavailable-color`, i.e. `--disabled-text-color`.
    public static let green = RGBColor(hex: 0x4CAF50)
    public static let red = RGBColor(hex: 0xF44336)
    public static let orange = RGBColor(hex: 0xFF9800)
    public static let unavailable = RGBColor(hex: 0xBDBDBD)

    public static let locked = "lock.fill"
    public static let unlocked = "lock.open.fill"
    /// Falls back to `locked` where this macOS has no such symbol.
    public static let jammed = "lock.trianglebadge.exclamationmark.fill"

    public init(symbol: String, color: RGBColor, isEnabled: Bool, action: LockControl.Action, label: String) {
        self.symbol = symbol
        self.color = color
        self.isEnabled = isEnabled
        self.action = action
        self.label = label
    }

    public init(state: EntityState?) {
        let action = LockControl.action(for: state)
        let text = LockControl.text(state)
        switch state?.state {
        case "locked"?:
            self.init(symbol: Self.locked, color: Self.green, isEnabled: true, action: action,
                      label: "Locked — click to unlock")
        case "unlocked"?, "open"?:
            self.init(symbol: Self.unlocked, color: Self.red, isEnabled: true, action: action,
                      label: "\(text) — click to lock")
        // Moving: the glyph it is heading for, in orange, and not clickable until
        // it gets there.
        case "locking"?:
            self.init(symbol: Self.locked, color: Self.orange, isEnabled: false, action: action, label: "Locking…")
        case "unlocking"?, "opening"?:
            self.init(symbol: Self.unlocked, color: Self.orange, isEnabled: false, action: action, label: "\(text)…")
        case "jammed"?:
            self.init(symbol: Self.jammed, color: Self.red, isEnabled: true, action: action,
                      label: "Jammed — click to lock again")
        default:
            self.init(symbol: Self.locked, color: Self.unavailable, isEnabled: false, action: action,
                      label: state == nil ? "Unavailable" : text)
        }
    }
}

/// Whether a section's lock moves onto its heading as a padlock: only when
/// the section has a heading to put it on and that lock is the only one in
/// it — two padlocks side by side would not say which door is which.
public enum LockPlacement {
    public static func promote(_ group: DeviceGroup) -> DeviceGroup {
        let locks = group.devices.filter { $0.kind == .lock }
        guard group.headed, locks.count == 1, let lock = locks.first else { return group }
        return DeviceGroup(title: group.title, devices: group.devices.filter { $0 != lock },
                           headingGauge: group.headingGauge, headingLock: lock, headed: true,
                           view: group.view, viewTitle: group.viewTitle)
    }
}
