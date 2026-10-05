// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit

/// An NSButton that runs a closure. Buttons inside a menu row act without
/// dismissing the menu, which is what every control here relies on.
class ClosureButton: NSButton {
    var onPress: (() -> Void)?

    /// A borderless glyph, the size of the menu's text: transport keys, cover
    /// arrows, the thermostat's steppers.
    convenience init(symbol: String, label: String, onPress: (() -> Void)? = nil) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        toolTip = label
        contentTintColor = .labelColor
        self.onPress = onPress
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() {
        onPress?()
    }
}

/// A push button for something that happens once — a remote key, a script, a
/// restart. When the dashboard card asks for confirmation, the first press
/// arms the button ("Confirm?", in red) and only a second press within a few
/// seconds acts: an alert would take the menu down with it.
final class PressButton: ClosureButton {
    private let confirmation: String?
    private var armed = false
    private var disarm: DispatchWorkItem?
    private var restingTitle = ""
    private var restingImage: NSImage?
    var onConfirmedPress: (() -> Void)?

    init(title: String, symbol: String?, iconOnly: Bool, confirmation: String?, onPress: @escaping () -> Void) {
        self.confirmation = confirmation
        super.init(frame: .zero)
        onConfirmedPress = onPress
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        lineBreakMode = .byTruncatingTail
        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        self.image = image
        self.title = iconOnly && image != nil ? "" : title
        imagePosition = image == nil ? .noImage : (self.title.isEmpty ? .imageOnly : .imageLeading)
        toolTip = confirmation ?? title
        setAccessibilityLabel(title)
        self.onPress = { [weak self] in self?.handlePress() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func handlePress() {
        guard confirmation != nil, !armed else {
            reset()
            onConfirmedPress?()
            return
        }
        armed = true
        restingTitle = title
        restingImage = image
        image = nil
        imagePosition = .noImage
        attributedTitle = NSAttributedString(string: "Confirm?", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold),
        ])
        let work = DispatchWorkItem { [weak self] in self?.reset() }
        disarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func reset() {
        disarm?.cancel()
        disarm = nil
        guard armed else { return }
        armed = false
        title = restingTitle
        image = restingImage
        imagePosition = image == nil ? .noImage : (title.isEmpty ? .imageOnly : .imageLeading)
    }
}
