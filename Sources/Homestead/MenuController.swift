// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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
    /// Everything on screen that shows an entity, by entity id. One entity can
    /// drive many rows — a remote backs every key of its D-pad — so updates
    /// fan out to all of them.
    private var updaters: [String: [(EntityState?) -> Void]] = [:]
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
        updaters.removeAll()

        let snapshot = model.snapshot

        if snapshot.connection == .unconfigured {
            menu.addItem(connectItem())
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

            // Buttons from one dashboard grid share a grid here, in its
            // columns; a lone one is a row with a Press button.
            var index = group.devices.startIndex
            while index < group.devices.endIndex {
                let device = group.devices[index]
                guard device.kind == .button else {
                    addDevice(device, to: menu, snapshot: snapshot)
                    index += 1
                    continue
                }
                let run = Array(group.devices[index...].prefix { $0.kind == .button && $0.layout == device.layout })
                index += run.count
                if run.count == 1 {
                    addButtonRow(device, to: menu, snapshot: snapshot)
                } else {
                    addButtonGrid(run, to: menu, snapshot: snapshot)
                }
            }
        }

        menu.addItem(.separator())
        addSettingsItems(menu)
    }

    /// Adds a menu item showing `view`, kept current from `entityId`'s state:
    /// `update` refreshes the view and `hidden` decides whether it shows at all
    /// (an open NSMenu re-lays out when an item's `isHidden` changes).
    @discardableResult
    private func addItem(_ view: NSView, to menu: NSMenu, entityId: String, state: EntityState?,
                         hidden: ((EntityState?) -> Bool)? = nil,
                         update: ((EntityState?) -> Void)? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        item.isHidden = hidden?(state) ?? false
        menu.addItem(item)
        updaters[entityId, default: []].append { state in
            update?(state)
            if let hidden { item.isHidden = hidden(state) }
        }
        return item
    }

    private static func isOff(_ state: EntityState?) -> Bool { !(state?.isOn ?? false) }

    private func addDevice(_ device: Device, to menu: NSMenu, snapshot: Snapshot) {
        let state = snapshot.states[device.entityId]
        let unit = snapshot.temperatureUnit
        let modes = device.domain == "climate" ? ThermostatModeView.modes(of: state) : []

        var showsSwitch: Bool?
        var accessory: NSView?
        var updateAccessory: ((EntityState?) -> Void)?
        switch device.kind {
        case .mediaPlayer:
            showsSwitch = MediaCapabilities.supportsPower(state)
        case .thermostat where modes.count > 1:
            showsSwitch = false
        case .cover where CoverControlsView.hasControls(state):
            let controls = CoverControlsView(state: state) { [weak self] motion in
                self?.model.moveCover(device, motion)
            }
            accessory = controls
            updateAccessory = controls.update(state:)
        default:
            break
        }

        let canPickColor = device.kind == .light && LightCapabilities.supportsColor(state)
        let row = DeviceRowView(
            device: device,
            state: state,
            temperatureUnit: unit,
            showsSwitch: showsSwitch,
            accessory: accessory,
            onToggle: { [weak self] on in self?.toggled(device, on: on) },
            onPickColor: canPickColor ? { [weak self] in self?.pickColor(for: device) } : nil
        )
        addItem(row, to: menu, entityId: device.entityId, state: state) { state in
            row.update(state: state)
            updateAccessory?(state)
        }

        switch device.kind {
        case .mediaPlayer:
            addMediaControls(to: menu, device: device, state: state)

        case .thermostat:
            if modes.count > 1 {
                let modeView = ThermostatModeView(modes: modes, state: state) { [weak self] mode in
                    self?.model.setHVACMode(device, mode)
                }
                addItem(modeView, to: menu, entityId: device.entityId, state: state, update: modeView.update(state:))
            }
            let target = ThermostatTargetView(state: state, unit: unit) { [weak self] targets in
                self?.model.setTargets(device, targets)
            }
            addItem(target, to: menu, entityId: device.entityId, state: state,
                    hidden: { !ThermostatTargetView.hasTargets($0) }, update: target.update(state:))

        case .light, .fan, .cover:
            guard device.kind.hasSlider else { return }
            // A shade's position is worth setting while it is closed — that is
            // how you open it half-way — so its slider never hides.
            let hidden: (EntityState?) -> Bool = device.kind == .light || device.kind == .fan ? Self.isOff : { _ in false }
            let slider = LevelSliderView(style: .level(device.kind),
                                         fraction: Self.fraction(device: device, state: state)) { [weak self] value in
                self?.model.setLevel(device, fraction: value)
            }
            addItem(slider, to: menu, entityId: device.entityId, state: state, hidden: hidden) { state in
                slider.update(fraction: Self.fraction(device: device, state: state))
            }

            // A tunable-white bulb gets a second slider. Colour and warmth
            // are different questions: the picker cannot express a precise
            // white, and this cannot express a colour.
            guard device.kind == .light, LightCapabilities.supportsColorTemperature(state) else { return }
            let warmth = LevelSliderView(style: .warmth,
                                         fraction: Self.warmthFraction(state: state),
                                         caption: Self.warmthCaption(state: state)) { [weak self] value in
                self?.model.setColorTemperature(device, fraction: value)
            }
            addItem(warmth, to: menu, entityId: device.entityId, state: state, hidden: Self.isOff) { state in
                warmth.update(fraction: Self.warmthFraction(state: state), caption: Self.warmthCaption(state: state))
            }

        case .toggle, .sensor, .button:
            break
        }
    }

    /// One button on its own: a row with its name and a Press button.
    private func addButtonRow(_ device: Device, to menu: NSMenu, snapshot: Snapshot) {
        let state = snapshot.states[device.entityId]
        let verb: String
        switch device.action?.domain ?? device.domain {
        case "script": verb = "Run"
        case "scene": verb = "Activate"
        default: verb = "Press"
        }
        let press = PressButton(title: verb, symbol: nil, iconOnly: false,
                                confirmation: device.action?.confirmation) { [weak self] in
            self?.model.press(device)
        }
        let row = DeviceRowView(device: device, state: state, showsSwitch: false, accessory: press, onToggle: { _ in })
        addItem(row, to: menu, entityId: device.entityId, state: state) { state in
            row.update(state: state)
            press.isEnabled = ButtonAvailability.isAvailable(state)
        }
        press.isEnabled = ButtonAvailability.isAvailable(state)
    }

    private func addButtonGrid(_ devices: [Device], to menu: NSMenu, snapshot: Snapshot) {
        let grid = ButtonGridView(devices: devices, columns: devices.first?.layout?.columns ?? 3) { [weak self] device in
            self?.model.press(device)
        }
        let item = NSMenuItem()
        item.view = grid
        menu.addItem(item)
        for entityId in Set(devices.map(\.entityId)) {
            grid.update(entityId: entityId, state: snapshot.states[entityId])
            updaters[entityId, default: []].append { grid.update(entityId: entityId, state: $0) }
        }
    }

    /// A player's controls are whatever it says it has: a TV with no transport
    /// gets only a volume slider, a speaker with no volume only a play button.
    private func addMediaControls(to menu: NSMenu, device: Device, state: EntityState?) {
        if MediaCapabilities.supportsVolume(state) {
            let slider = LevelSliderView(style: .level(.mediaPlayer),
                                         fraction: MediaCapabilities.volume(of: state) ?? 0) { [weak self] value in
                self?.model.setLevel(device, fraction: value)
            }
            addItem(slider, to: menu, entityId: device.entityId, state: state, hidden: Self.isOff) { state in
                slider.update(fraction: MediaCapabilities.volume(of: state) ?? 0)
            }
        }

        guard TransportRowView.hasControls(state) else { return }
        let transport = TransportRowView(state: state) { [weak self] control in
            self?.model.transport(device, control)
        }
        addItem(transport, to: menu, entityId: device.entityId, state: state,
                hidden: Self.isOff, update: transport.update(state:))
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
        case .authFailed: text = "Signed out"
        }
        guard let text else { return }

        let item = NSMenuItem()
        item.view = StatusRowView(text: text)
        item.isEnabled = false
        menu.addItem(item)

        if snapshot.connection == .authFailed {
            menu.addItem(connectItem())
        }

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
            let state = model.state(for: entityId)
            updaters[entityId]?.forEach { $0(state) }
        }
    }

    /// The dashboard changed, or sensors were switched on: rebuild in place if
    /// the menu is on screen.
    func rebuildIfOpen() {
        guard let menu, !menu.items.isEmpty else { return }
        menu.removeAllItems()
        build(menu)
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
        case .mediaPlayer: return MediaCapabilities.volume(of: state) ?? 0
        case .thermostat, .toggle, .sensor, .button: return 0
        }
    }

    // MARK: - Actions

    private func toggled(_ device: Device, on: Bool) {
        model.toggle(device, on: on)
        // Show the sliders immediately; the confirming state event follows.
        guard device.kind != .thermostat, var state = model.state(for: device.entityId) else { return }
        state.state = on ? "on" : "off"
        updaters[device.entityId]?.forEach { $0(state) }
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

    /// Whether the settings section offers Connection…: only when signed in,
    /// because signed out the menu already leads with Connect to Home Assistant….
    static func showsConnectionItem(_ connection: ConnectionState) -> Bool {
        connection != .unconfigured && connection != .authFailed
    }

    /// The one way in while signed out. Signed in, the same window is
    /// Connection… in the settings section instead (see `showsConnectionItem`).
    private func connectItem() -> NSMenuItem {
        let connect = NSMenuItem(title: "Connect to Home Assistant…",
                                 action: #selector(openConnection), keyEquivalent: "")
        connect.target = self
        return connect
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
