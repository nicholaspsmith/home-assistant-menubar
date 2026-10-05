// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore
import StatusItemKit
import os

let log = Logger(subsystem: "com.nicholaspsmith.Homestead", category: "app")

/// Homestead — Home Assistant devices in the menu bar. The dropdown's first row
/// picks a dashboard; the rest of it is that dashboard's devices.
@MainActor
final class App: NSObject, NSApplicationDelegate {
    private var status: StatusItemController!
    /// Steps this icon aside while Barn reveals its hidden block.
    private var yieldClient: YieldClient!
    let settings = Settings()
    /// The house is the default icon; Dot is the fallback for anyone who wants
    /// a plain status light. Neither varies with a fraction, so the
    /// proportional meters are not offered.
    private let appearance = MeterAppearance(defaultStyle: .character)
    private var appearanceMenu: AppearanceMenu!
    private var connectionWindow: ConnectionWindowController?
    private var dashboardsWindow: DashboardsWindowController?
    private(set) var model: AppModel!
    private var menuController: MenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window opens: it is what makes ⌘V work in them.
        MainMenu.install()

        status = StatusItemController(
            // Nothing is polled: state arrives on the socket. The timer is the
            // fallback that redraws the icon if a push is ever missed.
            pollInterval: 60,
            onPoll: { [weak self] in self?.refreshIcon() },
            onBuildMenu: { [weak self] menu in self?.buildMenu(menu) },
            autosaveName: "Homestead"
        )
        status.start()
        yieldClient = YieldClient(item: status)
        yieldClient.start()

        appearanceMenu = AppearanceMenu(appearance: appearance,
                                        styles: [.character, .dot],
                                        characterTitle: "House",
                                        onChange: { [weak self] in self?.refreshIcon() })

        // Keychain migrations run with the first token read, off the main
        // thread (TokenStore.loadInBackground): they can wait on a prompt.

        model = AppModel(settings: settings)
        menuController = MenuController(
            model: model,
            addSettingsItems: { [weak self] menu in self?.addSettingsItems(to: menu) },
            onOpenConnection: { [weak self] in self?.openConnection() }
        )
        model.onSnapshotChange = { [weak self] _ in
            self?.refreshIcon()
            self?.menuController.rebuildIfOpen()
        }
        model.onWeatherChange = { [weak self] in self?.refreshIcon() }
        model.onEntitiesChanged = { [weak self] entities in
            self?.menuController.apply(entities: entities)
        }
        status.onMenuDidClose = { [weak self] in self?.menuController.menuClosed() }
        model.start()
        refreshIcon()
    }

    // MARK: - Menu

    private func buildMenu(_ menu: NSMenu) {
        menuController.build(menu)
    }

    func addSettingsItems(to menu: NSMenu) {
        let sensors = NSMenuItem(title: "Show Sensors", action: #selector(toggleSensors), keyEquivalent: "")
        sensors.target = self
        sensors.state = settings.showSensors ? .on : .off
        menu.addItem(sensors)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(appearanceMenu.menuItem())
        if let weather = weatherMenuItem() { menu.addItem(weather) }

        let dashboards = NSMenuItem(title: "Dashboards…", action: #selector(openDashboards), keyEquivalent: "")
        dashboards.target = self
        dashboards.isEnabled = !model.allDashboards.isEmpty
        menu.addItem(dashboards)

        // Signed out, the menu leads with Connect to Home Assistant… instead.
        if MenuController.showsConnectionItem(model.snapshot.connection) {
            let connection = NSMenuItem(title: "Connection…", action: #selector(openConnection), keyEquivalent: "")
            connection.target = self
            menu.addItem(connection)
        }

        menu.addItem(.separator())
        menu.addItem(AppVersion.menuItem())
        menu.addItem(NSMenuItem(title: "Quit Homestead",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Weather ▸ Automatic, each weather entity, None. Absent when Home
    /// Assistant has no weather entity at all.
    private func weatherMenuItem() -> NSMenuItem? {
        let snapshot = model.snapshot
        guard !snapshot.weatherEntities.isEmpty else { return nil }
        let submenu = NSMenu()
        let chosen = settings.weatherEntity

        let automaticName = WeatherReport.automaticEntity(from: snapshot.weatherEntities.map(\.id))
            .flatMap { id in snapshot.weatherEntities.first { $0.id == id }?.name }
        let automatic = NSMenuItem(title: automaticName.map { "Automatic (\($0))" } ?? "Automatic",
                                   action: #selector(chooseWeather(_:)), keyEquivalent: "")
        automatic.state = chosen == nil ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(.separator())
        for entity in snapshot.weatherEntities {
            let item = NSMenuItem(title: entity.name, action: #selector(chooseWeather(_:)), keyEquivalent: "")
            item.representedObject = entity.id
            item.state = chosen == entity.id ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let none = NSMenuItem(title: "None", action: #selector(chooseWeather(_:)), keyEquivalent: "")
        none.representedObject = ""
        none.state = chosen == "" ? .on : .off
        submenu.addItem(none)
        for item in submenu.items { item.target = self }

        let item = NSMenuItem(title: "Weather", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func chooseWeather(_ sender: NSMenuItem) {
        model.setWeatherEntity(sender.representedObject as? String)
    }

    @objc private func toggleSensors() {
        model.setShowSensors(!settings.showSensors)
        menuController.rebuildIfOpen()
    }

    @objc private func toggleLogin() {
        LoginItem.toggle()
    }

    @objc func openConnection() {
        if connectionWindow == nil {
            connectionWindow = ConnectionWindowController(settings: settings) { [weak self] in
                self?.connectionSaved()
            }
        }
        connectionWindow?.show()
    }

    func connectionSaved() {
        model.reloadConfiguration()
    }

    @objc func openDashboards() {
        if dashboardsWindow == nil {
            dashboardsWindow = DashboardsWindowController(settings: settings) { [weak self] in
                self?.model.refreshVisibleDashboards()
            }
        }
        dashboardsWindow?.show(dashboards: model.allDashboards)
    }

    // MARK: - Icon

    func refreshIcon() {
        let snapshot = model?.snapshot ?? Snapshot()
        status.setIcon(HouseIcon.image(snapshot: snapshot, appearance: appearance))
        status.button?.toolTip = HouseIcon.toolTip(snapshot: snapshot)
    }
}

// Handle `--login on|off|status` and exit before any UI exists. Start at Login is
// SMAppService.mainApp, which can only register the calling process's own bundle,
// so this is the only way an installer or script can turn it on.
LoginCLI.runIfRequested()

// Top-level code is nonisolated, but this runs on the main thread by
// definition, which is what lets the whole app be `@MainActor`.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `delegate` stays alive for the process: run() never returns.
    app.run()
}
