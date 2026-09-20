// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// How long to wait before retry number `attempt` (0-based). Doubling from one
/// second, capped at thirty: a Mullvad connection can hide the server for
/// hours, and polling it every second for that long is pure noise.
public enum ReconnectPolicy {
    public static let maximumDelay: TimeInterval = 30

    public static func delay(attempt: Int) -> TimeInterval {
        let clamped = max(attempt, 0)
        guard clamped < 6 else { return maximumDelay }
        return min(pow(2, Double(clamped)), maximumDelay)
    }
}
