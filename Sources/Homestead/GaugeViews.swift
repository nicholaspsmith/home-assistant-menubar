// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore
import StatusItemKit

/// A dashboard gauge as a small arc meter and its value — the same arc the
/// menu-bar icon draws in Settings ▸ Icon ▸ Arc (`MeterIcon.arc`), filled to
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
        spacing = 3
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        label.textColor = .secondaryLabelColor
        arc.imageScaling = .scaleNone
        arc.widthAnchor.constraint(equalToConstant: 18).isActive = true
        arc.heightAnchor.constraint(equalToConstant: 18).isActive = true
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
        padlock?.symbolConfiguration = .init(pointSize: 13, weight: .semibold)

        let trailing = NSStackView(views: [padlock, meter].compactMap { $0 })
        trailing.orientation = .horizontal
        trailing.spacing = 10
        for view in [label, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])
        if let gauge { updateGauge(state: states[gauge.entityId]) }
        if let lock { updateLock(state: states[lock.entityId]) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateGauge(state: EntityState?) { meter?.update(state: state) }

    /// Closed and green when locked, open and orange when not, red when
    /// jammed; dim and unclickable while it moves or is gone.
    func updateLock(state: EntityState?) {
        guard let padlock else { return }
        let icon = LockIcon(state: state)
        padlock.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.label)
            ?? NSImage(systemSymbolName: LockIcon.locked, accessibilityDescription: icon.label)
        padlock.contentTintColor = NSColor(srgbRed: icon.color.red, green: icon.color.green,
                                           blue: icon.color.blue, alpha: 1)
        padlock.isEnabled = icon.isEnabled
        padlock.toolTip = icon.label
        padlock.setAccessibilityLabel(icon.label)
    }
}
