import AppKit
import HomesteadCore

/// Previous / play-pause / next for a media player, as a view-based row so the
/// menu stays open while you use them — which is the whole point: pausing
/// something should not cost you the menu you were in.
final class TransportRowView: NSView {
    init(showsSkip: Bool, onControl: @escaping (ServiceCall.Transport) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 26))

        var buttons: [NSButton] = []
        func button(_ symbol: String, _ control: ServiceCall.Transport) -> NSButton {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.title = ""
            button.contentTintColor = .labelColor
            button.target = ActionProxy.shared
            button.action = #selector(ActionProxy.run(_:))
            ActionProxy.shared.register(button) { onControl(control) }
            return button
        }

        if showsSkip { buttons.append(button("backward.end.fill", .previous)) }
        buttons.append(button("playpause.fill", .playPause))
        if showsSkip { buttons.append(button("forward.end.fill", .next)) }

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// NSButton needs an ObjC target; this keeps the closures alive for the life of
/// the menu without every button needing its own subclass.
private final class ActionProxy: NSObject {
    static let shared = ActionProxy()
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    func register(_ button: NSButton, _ action: @escaping () -> Void) {
        actions[ObjectIdentifier(button)] = action
    }

    @objc func run(_ sender: NSButton) {
        actions[ObjectIdentifier(sender)]?()
    }
}
