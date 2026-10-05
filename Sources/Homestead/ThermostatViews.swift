// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// Off / Heat / Cool / Heat·Cool, from the modes the thermostat reports. It
/// replaces the row's switch: "on" means nothing to a thermostat until you
/// say which way.
final class ThermostatModeView: NSView {
    private let control: NSSegmentedControl
    private let modes: [String]
    private let onChange: (String) -> Void

    static func modes(of state: EntityState?) -> [String] {
        state?.attributes["hvac_modes"]?.array?.compactMap(\.string) ?? []
    }

    static func label(_ mode: String) -> String {
        switch mode {
        case "heat_cool": return "Heat·Cool"
        case "fan_only": return "Fan"
        default: return mode.prefix(1).uppercased() + mode.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
    }

    init(modes: [String], state: EntityState?, onChange: @escaping (String) -> Void) {
        self.modes = modes
        self.onChange = onChange
        control = NSSegmentedControl(labels: modes.map(Self.label), trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 28))

        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        control.segmentDistribution = .fillEqually
        control.target = self
        control.action = #selector(changed)
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: EntityState?) {
        control.isEnabled = state?.isAvailable ?? false
        control.selectedSegment = state.flatMap { modes.firstIndex(of: $0.state) } ?? -1
    }

    @objc private func changed() {
        guard modes.indices.contains(control.selectedSegment) else { return }
        onChange(modes[control.selectedSegment])
    }
}

/// What the thermostat is set to — one temperature, or both ends of a
/// heat/cool band — as buttons. Click one to select it, then the arrows move
/// it a step at a time.
///
/// Arrow presses collect for a moment before anything is sent, so five quick
/// clicks are one call to the thermostat rather than five, and the number on
/// screen never jumps back to an in-between value as the echoes arrive.
final class ThermostatTargetView: NSView {
    private static let settle: TimeInterval = 0.8
    /// How long a sent value outranks the state Home Assistant reports, which
    /// lags the call by a round trip (or several, through a cloud thermostat).
    private static let echoGrace: TimeInterval = 5

    private let unit: String
    private let onSet: (ThermostatTargets) -> Void
    private var range: TemperatureRange
    private var targets: ThermostatTargets?
    private var selected: ThermostatTargets.Edge?
    private var pending: ThermostatTargets?
    private var pendingUntil = Date.distantPast
    private var sendWork: DispatchWorkItem?
    private var mode = ""
    private var available = false

    private let label = NSTextField(labelWithString: "Set to")
    private let chips = NSStackView()
    private let down = ClosureButton(symbol: "chevron.down", label: "Lower")
    private let up = ClosureButton(symbol: "chevron.up", label: "Raise")
    private var chipButtons: [ThermostatTargets.Edge: ClosureButton] = [:]

    init(state: EntityState?, unit: String, onSet: @escaping (ThermostatTargets) -> Void) {
        self.unit = unit
        self.onSet = onSet
        range = TemperatureRange(state: state, unit: unit)
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 28))

        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        label.textColor = .secondaryLabelColor
        chips.orientation = .horizontal
        chips.spacing = 4
        down.onPress = { [weak self] in self?.nudge(-1) }
        up.onPress = { [weak self] in self?.nudge(1) }
        for button in [down, up] {
            button.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        }

        for view in [label, chips, down, up] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chips.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            chips.centerYAnchor.constraint(equalTo: centerYAnchor),
            up.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            up.centerYAnchor.constraint(equalTo: centerYAnchor),
            up.widthAnchor.constraint(equalToConstant: 24),
            down.trailingAnchor.constraint(equalTo: up.leadingAnchor, constant: -4),
            down.centerYAnchor.constraint(equalTo: centerYAnchor),
            down.widthAnchor.constraint(equalToConstant: 24),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: down.leadingAnchor, constant: -8),
        ])
        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whether there is anything to show. A thermostat that is off in
    /// heat/cool mode reports no targets at all.
    static func hasTargets(_ state: EntityState?) -> Bool {
        ThermostatTargets.current(of: state) != nil
    }

    func update(state: EntityState?) {
        range = TemperatureRange(state: state, unit: unit)
        mode = state?.state ?? ""
        available = state?.isAvailable ?? false
        let reported = ThermostatTargets.current(of: state)
        // Until the thermostat confirms what was just sent, keep showing that.
        if let pending, reported != pending, Date() < pendingUntil {
            render(pending)
            return
        }
        pending = nil
        targets = reported
        render(reported)
    }

    private func render(_ targets: ThermostatTargets?) {
        let enabled = available
        let edges = targets?.edges ?? []
        if Set(chipButtons.keys) != Set(edges) {
            chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
            chipButtons.removeAll()
            for (index, edge) in edges.enumerated() {
                if index > 0 {
                    let dash = NSTextField(labelWithString: "–")
                    dash.textColor = .secondaryLabelColor
                    chips.addArrangedSubview(dash)
                }
                let chip = ClosureButton(frame: .zero)
                chip.setButtonType(.pushOnPushOff)
                chip.bezelStyle = .rounded
                chip.controlSize = .small
                chip.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
                chip.toolTip = "Click, then use the arrows to change"
                chip.onPress = { [weak self] in self?.select(edge) }
                chips.addArrangedSubview(chip)
                chipButtons[edge] = chip
            }
            if let selected, !edges.contains(selected) { self.selected = nil }
        }
        for (edge, chip) in chipButtons {
            let value = targets?.value(edge).map { TemperatureRange.format($0) + unit } ?? "–"
            // Selected, the chip fills with the accent colour; its tint would
            // vanish into it.
            chip.attributedTitle = NSAttributedString(string: value, attributes: [
                .foregroundColor: edge == selected ? NSColor.white : tint(for: edge),
                .font: chip.font ?? .systemFont(ofSize: 11),
            ])
            chip.state = edge == selected ? .on : .off
            chip.isEnabled = enabled
        }
        down.isEnabled = enabled && selected != nil
        up.isEnabled = enabled && selected != nil
        label.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    /// Warm for the heating end, cool for the cooling end — the colours Home
    /// Assistant's own thermostat card uses.
    private func tint(for edge: ThermostatTargets.Edge) -> NSColor {
        switch edge {
        case .low: return .systemOrange
        case .high: return .systemBlue
        case .single:
            switch mode {
            case "heat": return .systemOrange
            case "cool": return .systemBlue
            default: return .labelColor
            }
        }
    }

    private func select(_ edge: ThermostatTargets.Edge) {
        selected = selected == edge ? nil : edge
        render(pending ?? targets)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The menu closed or was rebuilt: a selection does not outlive it.
        guard window == nil else { return }
        selected = nil
    }

    private func nudge(_ steps: Int) {
        guard let selected, let current = pending ?? targets else { return }
        let next = current.nudged(selected, by: steps, in: range)
        guard next != current else { return }
        pending = next
        pendingUntil = Date().addingTimeInterval(Self.settle + Self.echoGrace)
        render(next)

        sendWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pending else { return }
            self.pendingUntil = Date().addingTimeInterval(Self.echoGrace)
            self.onSet(pending)
        }
        sendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }
}
