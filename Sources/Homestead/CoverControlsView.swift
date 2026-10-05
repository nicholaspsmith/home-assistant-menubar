// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// Open / stop / close for a blind or shade, in place of a switch: a shade
/// half-way down is neither on nor off, and the one thing a switch cannot do
/// is stop it where it is.
final class CoverControlsView: NSStackView {
    /// HA's `CoverEntityFeature` bits.
    private static let open = 1, close = 2, stop = 8

    private var buttons: [(motion: ServiceCall.CoverMotion, button: ClosureButton)] = []

    static func hasControls(_ state: EntityState?) -> Bool {
        (state?.attributes["supported_features"]?.int ?? 0) & (open | close | stop) != 0
    }

    init(state: EntityState?, onMotion: @escaping (ServiceCall.CoverMotion) -> Void) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        let features = state?.attributes["supported_features"]?.int ?? 0
        let keys: [(Int, String, String, ServiceCall.CoverMotion)] = [
            (Self.open, "chevron.up", "Open", .open),
            (Self.stop, "stop.fill", "Stop", .stop),
            (Self.close, "chevron.down", "Close", .close),
        ]
        for (bit, symbol, label, motion) in keys where features & bit != 0 {
            let button = ClosureButton(symbol: symbol, label: label) { onMotion(motion) }
            button.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            buttons.append((motion, button))
            addArrangedSubview(button)
        }
        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Open greys out once the shade is fully open, Close once it is shut;
    /// Stop is always there, since a report can lag a shade that is moving.
    func update(state: EntityState?) {
        let available = state?.isAvailable ?? false
        let position = state?.attributes["current_position"]?.int
        for (motion, button) in buttons {
            switch motion {
            // A shade half-way up reports "open", so its position decides.
            case .open: button.isEnabled = available && (state?.state != "open" || (position ?? 100) < 100)
            case .close: button.isEnabled = available && state?.state != "closed"
            case .stop: button.isEnabled = available
            }
        }
    }
}
