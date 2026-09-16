import AppKit
import HomesteadCore

/// The slider that appears under a device while it is on. Modelled on
/// KeyLight's backlight slider: continuous, and deaf to external updates while
/// it is being dragged.
final class LevelSliderView: NSView {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let onChange: (Double) -> Void

    init(kind: DeviceKind, fraction: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 24))

        slider.isContinuous = true
        slider.controlSize = .small
        slider.doubleValue = fraction
        slider.target = self
        slider.action = #selector(slid)

        let (lowName, highName) = Self.symbols(for: kind)
        let low = NSImageView(image: NSImage(systemSymbolName: lowName, accessibilityDescription: nil) ?? NSImage())
        let high = NSImageView(image: NSImage(systemSymbolName: highName, accessibilityDescription: nil) ?? NSImage())
        low.contentTintColor = .secondaryLabelColor
        high.contentTintColor = .secondaryLabelColor

        for view in [low, high, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            low.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            low.centerYAnchor.constraint(equalTo: centerYAnchor),
            low.widthAnchor.constraint(equalToConstant: 14),
            high.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            high.centerYAnchor.constraint(equalTo: centerYAnchor),
            high.widthAnchor.constraint(equalToConstant: 14),
            slider.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: high.leadingAnchor, constant: -6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reflect a change made elsewhere — unless this slider is the thing being
    /// changed, in which case the drag wins.
    func update(fraction: Double) {
        guard !slider.isHighlighted else { return }
        slider.doubleValue = fraction
    }

    private static func symbols(for kind: DeviceKind) -> (String, String) {
        switch kind {
        case .fan: return ("wind", "fanblades")
        case .cover: return ("blinds.horizontal.closed", "blinds.horizontal.open")
        default: return ("light.min", "light.max")
        }
    }

    @objc private func slid() {
        onChange(slider.doubleValue)
    }
}
