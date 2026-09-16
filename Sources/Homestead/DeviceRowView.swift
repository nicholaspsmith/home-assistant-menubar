import AppKit
import HomesteadCore

/// One device: name, its current value, and a switch. Lives in an NSMenuItem's
/// view, which is what lets a toggle act without dismissing the menu.
final class DeviceRowView: NSView {
    static let width: CGFloat = 280

    private let device: Device
    private let nameLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private let onToggle: (Bool) -> Void

    var switchIsOn: Bool { toggle.state == .on }

    init(device: Device, state: EntityState?, onToggle: @escaping (Bool) -> Void) {
        self.device = device
        self.onToggle = onToggle
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
        toggle.isHidden = !device.kind.hasSwitch

        for view in [nameLabel, valueLabel, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = [
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
        ]
        if device.kind.hasSwitch {
            constraints += [
                toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
                valueLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            ]
        } else {
            constraints.append(valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
        }
        NSLayoutConstraint.activate(constraints)

        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: EntityState?) {
        let available = state?.isAvailable ?? false
        toggle.isEnabled = available
        toggle.state = (state?.isOn ?? false) ? .on : .off
        nameLabel.textColor = available ? .labelColor : .tertiaryLabelColor
        valueLabel.stringValue = available ? Self.valueText(device: device, state: state) : "Unavailable"
    }

    static func valueText(device: Device, state: EntityState?) -> String {
        guard let state else { return "" }
        switch device.kind {
        case .light:
            guard state.isOn else { return "" }
            return "\(LevelMath.brightnessPct(from: LevelMath.fraction(brightness: state.attributes["brightness"])))%"
        case .fan:
            guard state.isOn else { return "" }
            return "\(Int((LevelMath.fraction(percentage: state.attributes["percentage"]) * 100).rounded()))%"
        case .cover(let positionable):
            let name = state.state.prefix(1).uppercased() + state.state.dropFirst()
            guard positionable, let position = state.attributes["current_position"]?.int else { return name }
            return "\(name) · \(position)%"
        case .toggle:
            return ""
        case .sensor:
            let unit = state.unit.map { " \($0)" } ?? ""
            switch state.state {
            case "on": return "On"
            case "off": return "Off"
            default: return state.state + unit
            }
        }
    }

    @objc private func flipped() {
        onToggle(toggle.state == .on)
    }
}
