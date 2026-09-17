import AppKit
import HomesteadCore

/// What a slider row is for. A light can have two of them — brightness and
/// warmth — so the row cannot take its identity from the device's kind alone.
enum SliderStyle: Equatable {
    case level(DeviceKind)
    /// Warm white to daylight.
    case warmth

    var symbols: (low: String, high: String) {
        switch self {
        case .warmth: return ("sun.horizon", "sun.max")
        case .level(.fan): return ("wind", "fanblades")
        case .level(.cover): return ("blinds.horizontal.closed", "blinds.horizontal.open")
        case .level(.thermostat): return ("thermometer.low", "thermometer.high")
        case .level(.mediaPlayer): return ("speaker.fill", "speaker.wave.3.fill")
        case .level: return ("light.min", "light.max")
        }
    }
}

/// The slider that appears under a device while it is on. Modelled on
/// KeyLight's backlight slider: continuous, and deaf to external updates while
/// it is being dragged.
final class LevelSliderView: NSView {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let captionLabel = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Void

    /// - Parameter caption: shown at the trailing end, for a slider whose value
    ///   is not already on the row above it — a thermostat's target, where the
    ///   row shows the current reading instead.
    init(style: SliderStyle, fraction: Double, caption: String? = nil, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 24))

        slider.isContinuous = true
        slider.controlSize = .small
        slider.doubleValue = fraction
        slider.target = self
        slider.action = #selector(slid)

        let (lowName, highName) = style.symbols
        let low = NSImageView(image: NSImage(systemSymbolName: lowName, accessibilityDescription: nil) ?? NSImage())
        let high = NSImageView(image: NSImage(systemSymbolName: highName, accessibilityDescription: nil) ?? NSImage())
        low.contentTintColor = .secondaryLabelColor
        high.contentTintColor = .secondaryLabelColor

        captionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .right
        captionLabel.stringValue = caption ?? ""
        captionLabel.isHidden = caption == nil

        for view in [low, high, slider, captionLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = [
            low.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            low.centerYAnchor.constraint(equalTo: centerYAnchor),
            low.widthAnchor.constraint(equalToConstant: 14),
            slider.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            high.centerYAnchor.constraint(equalTo: centerYAnchor),
            high.widthAnchor.constraint(equalToConstant: 14),
            slider.trailingAnchor.constraint(equalTo: high.leadingAnchor, constant: -6),
        ]
        if caption == nil {
            constraints.append(high.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
        } else {
            constraints += [
                high.trailingAnchor.constraint(equalTo: captionLabel.leadingAnchor, constant: -6),
                captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                captionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                captionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reflect a change made elsewhere — unless this slider is the thing being
    /// changed, in which case the drag wins.
    func update(fraction: Double, caption: String? = nil) {
        if let caption { captionLabel.stringValue = caption }
        guard !slider.isHighlighted else { return }
        slider.doubleValue = fraction
    }

    @objc private func slid() {
        onChange(slider.doubleValue)
    }
}
