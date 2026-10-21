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

/// A group heading with its section's gauge at the trailing end — a lock's
/// battery beside the lock's name. Looks like the plain heading items.
final class HeadingGaugeView: NSView {
    private let meter: GaugeMeterView

    init(title: String, gauge: Device, state: EntityState?) {
        meter = GaugeMeterView(gauge: gauge.gauge ?? GaugeSpec(), state: state)
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 22))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .disabledControlTextColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meter.setAccessibilityLabel(gauge.displayName)
        for view in [label, meter] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            meter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            meter.centerYAnchor.constraint(equalTo: centerYAnchor),
            meter.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: EntityState?) { meter.update(state: state) }
}
