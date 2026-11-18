// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// What a blind or shade's row says. The percentage is how far it is closed,
/// the same way round as its slider (`LevelMath.fraction(coverPosition:)`),
/// not Home Assistant's `current_position`, which counts how far it is open.
public enum CoverText {
    public static func text(_ state: EntityState, positionable: Bool) -> String {
        let name = state.state.prefix(1).uppercased() + state.state.dropFirst()
        guard positionable, state.attributes["current_position"]?.double != nil else { return name }
        let closed = LevelMath.coverClosedPercent(from: LevelMath.fraction(coverPosition: state.attributes["current_position"]))
        switch state.state {
        // A shade part-way down reports "open", and one being dragged open
        // still reports "closed": the percentage says more than either.
        case "open", "closed":
            return closed == 0 ? "Open" : closed == 100 ? "Closed" : "\(closed)% closed"
        case "opening", "closing":
            return "\(name) · \(closed)%"
        default:
            return name
        }
    }
}
