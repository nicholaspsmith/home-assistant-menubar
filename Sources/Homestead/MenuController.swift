import AppKit
import HomesteadCore

/// Builds the dropdown and keeps it honest while it is open. Rows are
/// view-based so toggling and dragging do not dismiss the menu; each device's
/// slider is a second item created up front and hidden until the device is on
/// (verified: an open NSMenu re-lays out when an item's `isHidden` changes).
///
/// `@MainActor` because it reads `AppModel`, which is main-actor isolated — and
/// because everything here is AppKit anyway.
@MainActor
final class MenuController: NSObject {
    private let model: AppModel
    private let addSettingsItems: (NSMenu) -> Void
    private let onOpenConnection: () -> Void

    private weak var menu: NSMenu?
    private var rows: [String: (item: NSMenuItem, view: DeviceRowView)] = [:]
    private var sliders: [String: (item: NSMenuItem, view: LevelSliderView)] = [:]
    private var devices: [String: Device] = [:]
    /// Whether the dashboard list is showing. Reset whenever the menu closes,
    /// so it always opens on the devices.
    private var pickerExpanded = false

    init(model: AppModel,
         addSettingsItems: @escaping (NSMenu) -> Void,
         onOpenConnection: @escaping () -> Void) {
        self.model = model
        self.addSettingsItems = addSettingsItems
        self.onOpenConnection = onOpenConnection
        super.init()
    }

    // MARK: - Building

    /// Called when the menu closes, so the next open starts on the devices.
    func menuClosed() {
        pickerExpanded = false
    }

    func build(_ menu: NSMenu) {
        self.menu = menu
        rows.removeAll()
        sliders.removeAll()
        devices.removeAll()

        let snapshot = model.snapshot

        if snapshot.connection == .unconfigured {
            let connect = NSMenuItem(title: "Connect to Home Assistant…",
                                     action: #selector(openConnection), keyEquivalent: "")
            connect.target = self
            menu.addItem(connect)
            menu.addItem(.separator())
            addSettingsItems(menu)
            return
        }

        addPicker(to: menu, snapshot: snapshot)
        addStatusRow(to: menu, snapshot: snapshot)

        if snapshot.groups.isEmpty, snapshot.connection == .connected, !pickerExpanded {
            let empty = NSMenuItem(title: "No controllable devices on this dashboard",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for group in pickerExpanded ? [] : snapshot.groups {
            let header = NSMenuItem(title: group.title.uppercased(), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for device in group.devices {
                devices[device.entityId] = device
                let state = snapshot.states[device.entityId]

                let rowItem = NSMenuItem()
                let rowView = DeviceRowView(device: device, state: state) { [weak self] on in
                    self?.toggled(device, on: on)
                }
                rowItem.view = rowView
                menu.addItem(rowItem)
                rows[device.entityId] = (rowItem, rowView)

                guard device.kind.hasSlider else { continue }
                let sliderItem = NSMenuItem()
                let sliderView = LevelSliderView(kind: device.kind,
                                                 fraction: Self.fraction(device: device, state: state)) { [weak self] value in
                    self?.model.setLevel(device, fraction: value)
                }
                sliderItem.view = sliderView
                sliderItem.isHidden = !(state?.isOn ?? false)
                menu.addItem(sliderItem)
                sliders[device.entityId] = (sliderItem, sliderView)
            }
        }

        menu.addItem(.separator())
        addSettingsItems(menu)
    }

    /// The dashboard picker expands in place rather than opening a submenu or a
    /// popup button. A popup button cannot be clicked at all while a menu is
    /// tracking (the menu owns the mouse), and a submenu would dismiss the whole
    /// menu on selection. View-based rows do neither: a click runs their handler
    /// and the menu stays open, so choosing a dashboard swaps the device rows
    /// under the pointer. While the list is expanded the device rows are hidden,
    /// which keeps the menu from becoming a two-screen-tall list.
    private func addPicker(to menu: NSMenu, snapshot: Snapshot) {
        let title = snapshot.selected?.title ?? "Dashboard"
        let headerItem = NSMenuItem()
        headerItem.view = DashboardHeaderView(title: title, expanded: pickerExpanded) { [weak self] in
            guard let self, !self.model.snapshot.dashboards.isEmpty else { return }
            self.pickerExpanded.toggle()
            self.rebuildIfOpen()
        }
        menu.addItem(headerItem)

        if pickerExpanded {
            for dashboard in snapshot.dashboards {
                let item = NSMenuItem()
                item.view = DashboardRowView(title: dashboard.title,
                                             isCurrent: dashboard.urlPath == snapshot.selected?.urlPath) { [weak self] in
                    self?.choose(dashboard)
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
    }

    private func addStatusRow(to menu: NSMenu, snapshot: Snapshot) {
        let text: String?
        switch snapshot.connection {
        case .connected, .unconfigured: text = nil
        case .connecting: text = "Connecting…"
        case .unreachable: text = "Can't reach Home Assistant — retrying"
        case .authFailed: text = "Token rejected — open Connection…"
        }
        guard let text else { return }

        let item = NSMenuItem()
        item.view = StatusRowView(text: text)
        item.isEnabled = false
        menu.addItem(item)

        if case .unreachable = snapshot.connection {
            let retry = NSMenuItem(title: "Retry Now", action: #selector(retry), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        menu.addItem(.separator())
    }

    // MARK: - Live updates

    /// Patch only the rows whose entities changed; rebuilding the whole menu
    /// under the cursor would fight whatever the user is doing in it.
    func apply(entities: Set<String>) {
        for entityId in entities {
            guard let device = devices[entityId] else { continue }
            let state = model.state(for: entityId)
            rows[entityId]?.view.update(state: state)

            guard let slider = sliders[entityId] else { continue }
            slider.item.isHidden = !(state?.isOn ?? false)
            slider.view.update(fraction: Self.fraction(device: device, state: state))
        }
    }

    /// The dashboard changed, or sensors were switched on: rebuild in place if
    /// the menu is on screen.
    func rebuildIfOpen() {
        guard let menu, !menu.items.isEmpty else { return }
        menu.removeAllItems()
        build(menu)
    }

    private static func fraction(device: Device, state: EntityState?) -> Double {
        guard let state else { return 0 }
        switch device.kind {
        case .light: return LevelMath.fraction(brightness: state.attributes["brightness"])
        case .fan: return LevelMath.fraction(percentage: state.attributes["percentage"])
        case .cover: return LevelMath.fraction(percentage: state.attributes["current_position"])
        case .toggle, .sensor: return 0
        }
    }

    // MARK: - Actions

    private func toggled(_ device: Device, on: Bool) {
        model.toggle(device, on: on)
        // Show the slider immediately; the confirming state event follows.
        sliders[device.entityId]?.item.isHidden = !on
    }

    private func choose(_ dashboard: DashboardListing) {
        pickerExpanded = false
        model.select(dashboard: dashboard)
        // The devices for the new dashboard arrive with its state; rebuild now
        // so the list collapses immediately rather than at the next event.
        rebuildIfOpen()
    }

    @objc private func retry() {
        model.retryNow()
    }

    @objc private func openConnection() {
        onOpenConnection()
    }
}

/// A plain text row. NSMenu reserves trailing space for the keyboard-shortcut
/// column on title-based items, which makes a status line look off-centre; a
/// view escapes that.
private final class StatusRowView: NSView {
    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 22))
        let label = NSTextField(labelWithString: text)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 3, width: DeviceRowView.width - 28, height: 16)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
