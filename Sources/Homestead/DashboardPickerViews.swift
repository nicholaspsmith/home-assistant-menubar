// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// The menu's first row: the current dashboard's name and a disclosure chevron.
/// Clicking it expands the dashboard list in place — no submenu, so the menu
/// stays open and switching dashboards can swap the device rows under the
/// pointer.
final class DashboardHeaderView: MenuRowView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    init(title: String, expanded: Bool, onClick: @escaping () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 28))
        self.onClick = onClick

        label.font = .menuBarFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = title

        let symbol = expanded ? "chevron.up" : "chevron.down"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        chevron.contentTintColor = .secondaryLabelColor

        for view in [label, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        label.textColor = rowTextColor
        chevron.contentTintColor = isRowHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
    }
}

/// One dashboard in the expanded list: a checkmark column and the title.
final class DashboardRowView: MenuRowView {
    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()

    init(title: String, isCurrent: Bool, onClick: @escaping () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 22))
        self.onClick = onClick

        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = title

        check.image = isCurrent ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
        check.contentTintColor = .labelColor

        for view in [check, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        label.textColor = rowTextColor
        check.contentTintColor = rowTextColor
    }
}
