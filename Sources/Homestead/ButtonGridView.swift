// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// Dashboard icons (`mdi:`) that have an SF Symbol meaning the same thing.
enum ButtonIcon {
    private static let symbols: [String: String] = [
        "arrow-left": "arrow.left", "arrow-right": "arrow.right",
        "arrow-up": "arrow.up", "arrow-down": "arrow.down",
        "arrow-u-left-top": "arrow.uturn.left", "keyboard-backspace": "arrow.uturn.left",
        "chevron-up": "chevron.up", "chevron-down": "chevron.down",
        "chevron-left": "chevron.left", "chevron-right": "chevron.right",
        "home": "house", "power": "power", "dots-horizontal": "ellipsis",
        "menu": "line.3.horizontal", "asterisk": "asterisk", "information": "info.circle",
        "rewind": "backward.fill", "fast-forward": "forward.fill",
        "play-pause": "playpause.fill", "play": "play.fill", "pause": "pause.fill", "stop": "stop.fill",
        "skip-next": "forward.end.fill", "skip-previous": "backward.end.fill",
        "volume-minus": "speaker.minus.fill", "volume-plus": "speaker.plus.fill",
        "volume-mute": "speaker.slash.fill", "volume-off": "speaker.slash.fill",
        "restore": "arrow.counterclockwise", "replay": "arrow.counterclockwise",
        "restart": "arrow.clockwise", "refresh": "arrow.clockwise", "sync": "arrow.triangle.2.circlepath",
        "microsoft-xbox": "gamecontroller", "television": "tv", "lightbulb": "lightbulb", "fan": "fan",
    ]

    /// Glyphs that need no label: a remote's arrows, transport and volume keys.
    /// Anything else ("restart", "sync") is ambiguous on its own and keeps its
    /// name — two buttons both drawn as a circular arrow would be a guess.
    private static let selfExplanatory: Set<String> = [
        "arrow.left", "arrow.right", "arrow.up", "arrow.down", "arrow.uturn.left",
        "chevron.up", "chevron.down", "chevron.left", "chevron.right",
        "house", "power", "ellipsis", "line.3.horizontal",
        "backward.fill", "forward.fill", "playpause.fill", "play.fill", "pause.fill", "stop.fill",
        "forward.end.fill", "backward.end.fill",
        "speaker.minus.fill", "speaker.plus.fill", "speaker.slash.fill",
    ]

    static func symbol(for icon: String?) -> String? {
        guard let icon else { return nil }
        let name = icon.hasPrefix("mdi:") ? String(icon.dropFirst(4)) : icon
        return symbols[name]
    }

    static func isSelfExplanatory(_ symbol: String?) -> Bool {
        symbol.map(selfExplanatory.contains) ?? false
    }
}

/// A run of dashboard buttons laid out as the dashboard's grid does — the
/// Studio TV remote is a 3×3 D-pad, and reads as one only when it looks like
/// one. Each key presses without closing the menu.
final class ButtonGridView: NSView {
    private static let spacing: CGFloat = 6
    private var buttons: [(entityId: String, button: PressButton)] = []

    /// - Parameter columns: the dashboard grid's; fewer when the labels would
    ///   not fit in a menu's width.
    init(devices: [Device], columns preferred: Int, onPress: @escaping (Device) -> Void) {
        let cells = devices.map { device -> (Device, String?, Bool) in
            let symbol = ButtonIcon.symbol(for: device.icon)
            return (device, symbol, ButtonIcon.isSelfExplanatory(symbol))
        }
        let longestTitle = cells.filter { !$0.2 }.map(\.0.displayName.count).max() ?? 0
        let fits: Int
        switch longestTitle {
        case 17...: fits = 1
        case 10...: fits = 2
        default: fits = 4
        }
        let columns = max(1, min(preferred, fits, devices.count))
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 0))

        let grid = NSGridView(numberOfColumns: columns, rows: 0)
        grid.columnSpacing = Self.spacing
        grid.rowSpacing = Self.spacing / 2
        var row: [NSView] = []
        for (device, symbol, iconOnly) in cells {
            // A named key is just its name: an icon beside centred text sits
            // in a different place on every key and lines up with nothing.
            let button = PressButton(title: device.displayName, symbol: iconOnly ? symbol : nil, iconOnly: iconOnly,
                                     confirmation: device.action?.confirmation) { onPress(device) }
            button.translatesAutoresizingMaskIntoConstraints = false
            buttons.append((device.entityId, button))
            row.append(button)
            if row.count == columns {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty { grid.addRow(with: row + Array(repeating: NSGridCell.emptyContentView, count: columns - row.count)) }
        for index in 0..<grid.numberOfColumns {
            grid.column(at: index).xPlacement = .fill
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        let inner = DeviceRowView.width - 28 - CGFloat(columns - 1) * Self.spacing
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            grid.centerYAnchor.constraint(equalTo: centerYAnchor),
        ] + buttons.map { $0.button.widthAnchor.constraint(equalToConstant: inner / CGFloat(columns)) })
        // A menu item's view is sized by its frame, not by constraints.
        setFrameSize(NSSize(width: DeviceRowView.width, height: grid.fittingSize.height + 10))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A key on a remote that has dropped off the network cannot be pressed.
    func update(entityId: String, state: EntityState?) {
        for entry in buttons where entry.entityId == entityId {
            entry.button.isEnabled = ButtonAvailability.isAvailable(state)
        }
    }
}

enum ButtonAvailability {
    /// A button entity's state is when it was last pressed, so a button never
    /// pressed is `unknown` and perfectly usable; only `unavailable` means the
    /// device is gone. An action with no entity behind it has no state at all.
    static func isAvailable(_ state: EntityState?) -> Bool {
        state?.state != "unavailable"
    }
}
