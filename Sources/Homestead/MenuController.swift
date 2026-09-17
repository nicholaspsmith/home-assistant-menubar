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
final class MenuController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let addSettingsItems: (NSMenu) -> Void
    private let onOpenConnection: () -> Void

    private weak var menu: NSMenu?
    private var rows: [String: (item: NSMenuItem, view: DeviceRowView)] = [:]
    private var sliders: [String: (item: NSMenuItem, view: LevelSliderView)] = [:]
    private var warmthSliders: [String: (item: NSMenuItem, view: LevelSliderView)] = [:]
    private var devices: [String: Device] = [:]
    /// Whether the dashboard list is showing. Reset whenever the menu closes,
    /// so it always opens on the devices.
    private var pickerExpanded = false
    /// The light the shared colour panel is currently driving.
    private var colorTarget: Device?

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
        warmthSliders.removeAll()
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
                let canPickColor = device.kind == .light && LightCapabilities.supportsColor(state)
                let rowView = DeviceRowView(
                    device: device,
                    state: state,
                    temperatureUnit: snapshot.temperatureUnit,
                    onToggle: { [weak self] on in self?.toggled(device, on: on) },
                    onPickColor: canPickColor ? { [weak self] in self?.pickColor(for: device) } : nil
                )
                rowItem.view = rowView
                menu.addItem(rowItem)
                rows[device.entityId] = (rowItem, rowView)

                guard device.kind.hasSlider else { continue }
                let sliderItem = NSMenuItem()
                let sliderView = LevelSliderView(
                    style: .level(device.kind),
                    fraction: Self.fraction(device: device, state: state),
                    caption: Self.sliderCaption(device: device, state: state, snapshot: snapshot)
                ) { [weak self] value in
                    self?.model.setLevel(device, fraction: value)
                }
                sliderItem.view = sliderView
                sliderItem.isHidden = Self.sliderIsHidden(device: device, state: state)
                menu.addItem(sliderItem)
                sliders[device.entityId] = (sliderItem, sliderView)

                // A tunable-white bulb gets a second slider. Colour and warmth
                // are different questions: the picker cannot express a precise
                // white, and this cannot express a colour.
                guard device.kind == .light, LightCapabilities.supportsColorTemperature(state) else { continue }
                let warmthItem = NSMenuItem()
                let warmthView = LevelSliderView(
                    style: .warmth,
                    fraction: Self.warmthFraction(state: state),
                    caption: Self.warmthCaption(state: state)
                ) { [weak self] value in
                    self?.model.setColorTemperature(device, fraction: value)
                }
                warmthItem.view = warmthView
                warmthItem.isHidden = Self.sliderIsHidden(device: device, state: state)
                menu.addItem(warmthItem)
                warmthSliders[device.entityId] = (warmthItem, warmthView)
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

            if let slider = sliders[entityId] {
                slider.item.isHidden = Self.sliderIsHidden(device: device, state: state)
                slider.view.update(fraction: Self.fraction(device: device, state: state),
                                   caption: Self.sliderCaption(device: device, state: state, snapshot: model.snapshot))
            }
            if let warmth = warmthSliders[entityId] {
                warmth.item.isHidden = Self.sliderIsHidden(device: device, state: state)
                warmth.view.update(fraction: Self.warmthFraction(state: state),
                                   caption: Self.warmthCaption(state: state))
            }
        }
    }

    /// The dashboard changed, or sensors were switched on: rebuild in place if
    /// the menu is on screen.
    func rebuildIfOpen() {
        guard let menu, !menu.items.isEmpty else { return }
        menu.removeAllItems()
        build(menu)
    }

    /// A level slider is only useful while the device is doing something —
    /// except a thermostat's, where the set point matters whether or not it is
    /// currently heating, and is usually what you want to change before
    /// turning it on.
    private static func sliderIsHidden(device: Device, state: EntityState?) -> Bool {
        guard device.kind != .thermostat else { return false }
        return !(state?.isOn ?? false)
    }

    private static func warmthFraction(state: EntityState?) -> Double {
        guard let kelvin = ColorTemperatureRange.current(of: state) else { return 0.5 }
        return ColorTemperatureRange(state: state).fraction(of: kelvin)
    }

    private static func warmthCaption(state: EntityState?) -> String {
        guard let kelvin = ColorTemperatureRange.current(of: state) else { return "" }
        return "\(Int(kelvin))K"
    }

    private static func fraction(device: Device, state: EntityState?) -> Double {
        guard let state else { return 0 }
        switch device.kind {
        case .light: return LevelMath.fraction(brightness: state.attributes["brightness"])
        case .fan: return LevelMath.fraction(percentage: state.attributes["percentage"])
        case .cover: return LevelMath.fraction(percentage: state.attributes["current_position"])
        case .thermostat:
            // The slider sets the target, so it sits where the target is — not
            // where the room currently happens to be.
            guard let target = TemperatureRange.target(of: state) else { return 0 }
            return TemperatureRange(state: state).fraction(of: target)
        case .toggle, .sensor: return 0
        }
    }

    /// A thermostat's slider says what temperature it is setting; a brightness
    /// slider needs no caption, since the row already shows the percentage.
    private static func sliderCaption(device: Device, state: EntityState?, snapshot: Snapshot) -> String? {
        guard device.kind == .thermostat, let target = TemperatureRange.target(of: state) else { return nil }
        return TemperatureRange.format(target) + snapshot.temperatureUnit
    }

    // MARK: - Actions

    private func toggled(_ device: Device, on: Bool) {
        model.toggle(device, on: on)
        // Show the sliders immediately; the confirming state event follows.
        guard device.kind != .thermostat else { return }
        sliders[device.entityId]?.item.isHidden = !on
        warmthSliders[device.entityId]?.item.isHidden = !on
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

    /// Opens the system colour panel for a light. The menu closes as the panel
    /// takes focus — unavoidable, and the same thing the shared Icon ▸ Custom
    /// Colour… picker does — but the light keeps following the wheel live.
    private func pickColor(for device: Device) {
        colorTarget = device
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let rgb = LightCapabilities.currentColor(model.state(for: device.entityId)) {
            panel.color = NSColor(srgbRed: CGFloat(rgb.red) / 255,
                                  green: CGFloat(rgb.green) / 255,
                                  blue: CGFloat(rgb.blue) / 255,
                                  alpha: 1)
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.delegate = self
        // An .accessory app has no windows and cannot bring a panel forward
        // without activating first.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let device = colorTarget,
              let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        model.setColor(device,
                       red: Int((rgb.redComponent * 255).rounded()),
                       green: Int((rgb.greenComponent * 255).rounded()),
                       blue: Int((rgb.blueComponent * 255).rounded()))
    }

    @objc private func openConnection() {
        onOpenConnection()
    }
}

extension MenuController {
    /// Stop driving a light once the panel is dismissed. Leaving the target
    /// attached means the next app to open the shared panel would start
    /// recolouring this one's bulb.
    public func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSColorPanel) === NSColorPanel.shared else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.delegate = nil
        colorTarget = nil
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
