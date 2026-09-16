import AppKit
import HomesteadCore

/// A scroll view's document view has to be flipped, or its rows stack up from
/// the bottom of the scroller and start scrolled to the end.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Ticks which dashboards the picker offers. Home Assistant happily holds
/// dozens; a menu is not the place to scroll through all of them, and which few
/// matter is a question only the person using it can answer.
///
/// Changes apply as they are made — there is nothing here worth a Save button,
/// and a cancelled dialog would only raise the question of what "cancel" undoes.
@MainActor
final class DashboardsWindowController: NSWindowController {
    private let settings: Settings
    private let onChange: () -> Void
    private var checkboxes: [NSButton] = []
    private let stack = FlippedStackView()

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dashboards"
        window.minSize = NSSize(width: 300, height: 240)
        super.init(window: window)
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(dashboards: [DashboardListing]) {
        populate(dashboards)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let caption = NSTextField(wrappingLabelWithString:
            "Show these dashboards in the menu. With none ticked, all of them are shown.")
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack

        for view in [caption, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            // Pin the stack to the CLIP view, never to the scroll view: tying
            // its width to the scroll view makes width circular (the scroll
            // sizes to its content, the content to the scroll), and autolayout
            // settles that at zero — which collapsed this window to 40pt with
            // nothing visible in it.
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            // Nothing inside has an intrinsic width, so the window needs a size
            // of its own to keep. minSize only limits dragging, not layout.
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    private func populate(_ dashboards: [DashboardListing]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        checkboxes.removeAll()

        let chosen = Set(settings.visibleDashboardPaths)
        for dashboard in dashboards {
            let box = NSButton(checkboxWithTitle: dashboard.title, target: self, action: #selector(toggled))
            box.state = chosen.contains(dashboard.urlPath ?? "") ? .on : .off
            box.identifier = NSUserInterfaceItemIdentifier(dashboard.urlPath ?? "")
            stack.addArrangedSubview(box)
            checkboxes.append(box)
        }
    }

    @objc private func toggled() {
        settings.visibleDashboardPaths = checkboxes
            .filter { $0.state == .on }
            .compactMap { $0.identifier?.rawValue }
        onChange()
    }
}
