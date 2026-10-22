// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore
import StatusItemKit

/// A dashboard gauge as a small arc meter and its value — the same arc the
/// menu-bar icon draws in Icon ▸ Arc (`MeterIcon.arc`), filled to
/// the value's place between the card's min and max and coloured by its
/// severity the way Home Assistant colours the card.
final class GaugeMeterView: NSStackView {
    private let gauge: GaugeSpec
    private let arc = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(gauge: GaugeSpec, state: EntityState?) {
        self.gauge = gauge
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = HeadingColumns.arcToValue
        label.font = HeadingColumns.valueFont
        label.textColor = .secondaryLabelColor
        // A fixed width, right-aligned, so "88%" and "100%" leave the arc in
        // the same place.
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: HeadingColumns.valueWidth).isActive = true
        arc.imageScaling = .scaleNone
        arc.widthAnchor.constraint(equalToConstant: HeadingColumns.icon).isActive = true
        arc.heightAnchor.constraint(equalToConstant: HeadingColumns.icon).isActive = true
        addArrangedSubview(arc)
        addArrangedSubview(label)
        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: EntityState?) {
        guard let state, state.isAvailable, let value = Double(state.state) else {
            arc.image = MeterIcon.arc(fraction: 0, color: .tertiaryLabelColor)
            label.stringValue = "—"
            toolTip = nil
            return
        }
        let color = gauge.color(for: value) ?? GaugeSpec.info
        arc.image = MeterIcon.arc(fraction: gauge.fraction(of: value),
                                  color: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        label.stringValue = SensorText.text(state)
        toolTip = state.friendlyName
    }
}

/// A group heading with its section's lock and gauge at the trailing end —
/// a door's name, a padlock to lock or unlock it, its battery. Looks like the
/// plain heading items.
final class HeadingView: NSView {
    private let meter: GaugeMeterView?
    private let padlock: ClosureButton?

    init(title: String, gauge: Device?, lock: Device?, states: [String: EntityState],
         onLock: @escaping (Device) -> Void) {
        meter = gauge.map { GaugeMeterView(gauge: $0.gauge ?? GaugeSpec(), state: states[$0.entityId]) }
        padlock = lock.map { lock in ClosureButton(symbol: LockIcon.locked, label: lock.displayName) { onLock(lock) } }
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 22))

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .disabledControlTextColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meter?.setAccessibilityLabel(gauge?.displayName)
        padlock?.imagePosition = .imageOnly
        padlock?.imageScaling = .scaleNone

        // Two fixed columns against the trailing edge — padlock, then arc and
        // value — so every heading's icons line up whatever its text or value.
        // A heading with only one of them keeps the other's slot empty.
        let lockSlot = NSView()
        let meterSlot = NSView()
        for view in [label, lockSlot, meterSlot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HeadingColumns.inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            meterSlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HeadingColumns.inset),
            meterSlot.widthAnchor.constraint(equalToConstant: HeadingColumns.meterWidth),
            meterSlot.topAnchor.constraint(equalTo: topAnchor),
            meterSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
            lockSlot.trailingAnchor.constraint(equalTo: meterSlot.leadingAnchor, constant: -HeadingColumns.gap),
            lockSlot.widthAnchor.constraint(equalToConstant: HeadingColumns.icon),
            lockSlot.topAnchor.constraint(equalTo: topAnchor),
            lockSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: lockSlot.leadingAnchor, constant: -HeadingColumns.gap),
        ]
        if let padlock {
            padlock.translatesAutoresizingMaskIntoConstraints = false
            lockSlot.addSubview(padlock)
            constraints += [
                padlock.centerXAnchor.constraint(equalTo: lockSlot.centerXAnchor),
                padlock.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                padlock.widthAnchor.constraint(equalToConstant: HeadingColumns.icon),
                padlock.heightAnchor.constraint(equalToConstant: HeadingColumns.icon),
            ]
        }
        if let meter {
            meter.translatesAutoresizingMaskIntoConstraints = false
            meterSlot.addSubview(meter)
            constraints += [
                meter.trailingAnchor.constraint(equalTo: meterSlot.trailingAnchor),
                meter.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        if let gauge { updateGauge(state: states[gauge.entityId]) }
        if let lock { updateLock(state: states[lock.entityId]) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateGauge(state: EntityState?) { meter?.update(state: state) }

    /// Closed and green when locked, open and red when not, red when
    /// jammed; dim and unclickable while it moves or is gone.
    func updateLock(state: EntityState?) {
        guard let padlock else { return }
        let icon = LockIcon(state: state)
        // Drawn on the same 18 pt canvas as the arc (`MeterIcon.symbol`), so
        // a wide glyph (jammed) sits in exactly the same place as a narrow
        // one and the column stays straight.
        let symbol = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) != nil
            ? icon.symbol : LockIcon.locked
        padlock.image = MeterIcon.symbol(symbol,
                                         color: NSColor(srgbRed: icon.color.red, green: icon.color.green,
                                                        blue: icon.color.blue, alpha: 1),
                                         pointSize: HeadingColumns.symbolPointSize)
        padlock.isEnabled = icon.isEnabled
        padlock.toolTip = icon.label
        padlock.setAccessibilityLabel(icon.label)
    }
}

/// The heading row's trailing columns: one width for every heading, so the
/// padlocks form one column and the arcs another.
enum HeadingColumns {
    static let inset: CGFloat = 14
    static let gap: CGFloat = 8
    /// The padlock's slot, and the arc image: both 18 pt square.
    static let icon: CGFloat = 18
    static let symbolPointSize: CGFloat = 13
    static let arcToValue: CGFloat = 3
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
    /// Wide enough for "100%", the widest a gauge's value usually gets.
    static let valueWidth: CGFloat = ceil(("100%" as NSString).size(withAttributes: [.font: valueFont]).width) + 2
    static var meterWidth: CGFloat { icon + arcToValue + valueWidth }
}
