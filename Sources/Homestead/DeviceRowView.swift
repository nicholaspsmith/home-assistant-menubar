// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// One device: name, its current value, and a switch — or, for things a switch
/// would misdescribe, whatever trailing control fits (a cover's open/stop/close,
/// a button's Press). Lives in an NSMenuItem's view, which is what lets a
/// control act without dismissing the menu.
final class DeviceRowView: NSView {
    static let width: CGFloat = 280

    private let device: Device
    private let nameLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private let swatch = NSButton()
    private let accessory: NSView?
    private let showsSwitch: Bool
    private let onToggle: (Bool) -> Void
    private let onPickColor: (() -> Void)?
    /// How Home Assistant writes temperatures for this house, e.g. "°C".
    private let temperatureUnit: String

    var switchIsOn: Bool { toggle.state == .on }

    /// - Parameters:
    ///   - showsSwitch: false where the entity cannot honestly be switched —
    ///     a player with no power control, a thermostat whose mode row does it.
    ///   - accessory: a trailing control shown in the switch's place.
    ///   - onPickColor: supplied only for a light whose bulb actually takes a
    ///     colour; the row then shows a swatch that opens the picker.
    init(device: Device,
         state: EntityState?,
         temperatureUnit: String = "°",
         showsSwitch: Bool? = nil,
         accessory: NSView? = nil,
         onToggle: @escaping (Bool) -> Void,
         onPickColor: (() -> Void)? = nil) {
        self.device = device
        self.showsSwitch = showsSwitch ?? device.kind.hasSwitch
        self.accessory = accessory
        self.onToggle = onToggle
        self.onPickColor = onPickColor
        self.temperatureUnit = temperatureUnit
        nameLabel = NSTextField(labelWithString: device.displayName)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 26))

        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(flipped)
        toggle.isHidden = !self.showsSwitch

        // A colour well would be the obvious control, but NSColorWell opens the
        // panel by running its own tracking, which a tracking menu will not let
        // it do. A plain button that opens NSColorPanel itself works from here.
        swatch.isBordered = false
        swatch.bezelStyle = .regularSquare
        swatch.title = ""
        swatch.target = self
        swatch.action = #selector(pickColor)
        swatch.isHidden = onPickColor == nil
        swatch.toolTip = "Set colour"

        for view in [nameLabel, valueLabel, swatch, toggle] + [accessory].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = [
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
        ]
        // The control at the trailing edge, which the value text sits against.
        var trailingControl: NSView?
        if self.showsSwitch {
            trailingControl = toggle
        } else if let accessory {
            trailingControl = accessory
        }
        if let trailingControl {
            constraints += [
                trailingControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                trailingControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        if let trailingControl, onPickColor != nil {
            constraints += [
                swatch.trailingAnchor.constraint(equalTo: trailingControl.leadingAnchor, constant: -8),
                swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
                swatch.widthAnchor.constraint(equalToConstant: 14),
                swatch.heightAnchor.constraint(equalToConstant: 14),
                valueLabel.trailingAnchor.constraint(equalTo: swatch.leadingAnchor, constant: -8),
            ]
        } else if let trailingControl {
            constraints.append(valueLabel.trailingAnchor.constraint(equalTo: trailingControl.leadingAnchor, constant: -8))
        } else {
            constraints.append(valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
        }
        NSLayoutConstraint.activate(constraints)

        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: EntityState?) {
        let available = device.kind == .button ? ButtonAvailability.isAvailable(state) : (state?.isAvailable ?? false)
        toggle.isEnabled = available
        toggle.state = (state?.isOn ?? false) ? .on : .off
        nameLabel.textColor = available ? .labelColor : .tertiaryLabelColor
        valueLabel.stringValue = available
            ? Self.valueText(device: device, state: state, temperatureUnit: temperatureUnit)
            : "Unavailable"

        if onPickColor != nil {
            // A light that is off reports no colour, and an empty ring sitting
            // in the row reads as a rendering fault rather than a control. The
            // swatch appears once there is a colour to show.
            let colour = LightCapabilities.currentColor(state)
            swatch.isHidden = colour == nil || !available
            swatch.isEnabled = available
            swatch.image = Self.swatchImage(for: state)
        }
    }

    /// A filled circle in the light's current colour. Only drawn when there is
    /// one: see `update(state:)`.
    private static func swatchImage(for state: EntityState?) -> NSImage {
        let rgb = LightCapabilities.currentColor(state)
        let colour = rgb.map {
            NSColor(srgbRed: CGFloat($0.red) / 255, green: CGFloat($0.green) / 255, blue: CGFloat($0.blue) / 255, alpha: 1)
        }
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 12, height: 12))
            if let colour {
                colour.setFill()
                circle.fill()
            }
            NSColor.tertiaryLabelColor.setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func pickColor() {
        onPickColor?()
    }

    static func valueText(device: Device, state: EntityState?, temperatureUnit: String = "°") -> String {
        guard let state else { return "" }
        switch device.kind {
        case .thermostat:
            return TemperatureRange.text(state: state, unit: temperatureUnit)
        case .mediaPlayer:
            return MediaCapabilities.text(state: state)
        // No level yet — the moment after the switch flips, before the light
        // reports one — shows nothing rather than a made-up 1%.
        case .light:
            guard state.isOn, state.attributes["brightness"]?.double != nil else { return "" }
            return "\(LevelMath.brightnessPct(from: LevelMath.fraction(brightness: state.attributes["brightness"])))%"
        case .fan:
            guard state.isOn, state.attributes["percentage"]?.double != nil else { return "" }
            return "\(Int((LevelMath.fraction(percentage: state.attributes["percentage"]) * 100).rounded()))%"
        case .cover(let positionable):
            let name = state.state.prefix(1).uppercased() + state.state.dropFirst()
            guard positionable, let position = state.attributes["current_position"]?.int else { return name }
            return "\(name) · \(position)%"
        case .toggle, .button:
            return ""
        case .sensor:
            return SensorText.text(state)
        }
    }

    @objc private func flipped() {
        onToggle(toggle.state == .on)
    }
}
