// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// What a lock's row says and what its one button does. A lock is not a
/// switch: unlocking a door from a menu should take a second, deliberate
/// press, and a lock part-way through moving has no honest on/off.
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

        /// Unlocking asks first; locking never does — a door left locked by
        /// a stray click is the safe mistake.
        public var needsConfirmation: Bool { self == .unlock }
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
