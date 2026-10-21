// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// A lock's one button: Lock when it is not locked, Unlock when it is. Both
/// act on the first press.
final class LockButton: PressButton {
    /// What the next (confirmed) press does. Not `action`: that is
    /// NSControl's selector.
    private(set) var lockAction: LockControl.Action

    init(state: EntityState?, onAction: @escaping (LockControl.Action) -> Void) {
        let action = LockControl.action(for: state)
        lockAction = action
        super.init(title: action.title, symbol: nil, iconOnly: false,
                   confirmation: nil, onPress: {})
        onConfirmedPress = { [weak self] in
            guard let self else { return }
            onAction(self.lockAction)
        }
        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Follows the lock: the button flips once the lock reports the new
    /// state, and is off while it is moving or gone.
    func update(state: EntityState?) {
        let next = LockControl.action(for: state)
        if next != lockAction {
            lockAction = next
            retitle(next.title, confirmation: nil)
        }
        isEnabled = LockControl.isEnabled(state)
    }
}

/// An `input_select` or `select` row's current option, as a button with a
/// disclosure chevron. Clicking it expands the options under the row inside
/// the menu, the way the dashboard picker does: a popup button cannot be
/// clicked while a menu tracks, and a submenu would close the menu on
/// selection.
final class SelectValueButton: ClosureButton {
    init(state: EntityState?, expanded: Bool, onPress: @escaping () -> Void) {
        super.init(frame: .zero)
        self.onPress = onPress
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .small
        font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        contentTintColor = .secondaryLabelColor
        lineBreakMode = .byTruncatingTail
        image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
                        accessibilityDescription: expanded ? "Hide options" : "Show options")
        symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        imagePosition = .imageTrailing
        toolTip = "Choose an option"
        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: EntityState?) {
        let canChoose = SelectOptions.canChoose(state)
        // Unavailable is already the row's value text; an empty button beside
        // it would only be something to click that does nothing.
        isHidden = !canChoose
        isEnabled = canChoose
        let current = state?.state ?? ""
        title = SelectOptions.options(of: state).contains(current) ? current : "Choose…"
    }
}
