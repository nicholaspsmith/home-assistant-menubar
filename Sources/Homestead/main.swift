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

        // A keychain item created by an earlier build trusts only that build's
        // binary, so relax what we can. (Not sufficient on its own for a
        // rebuilt app — see TokenStore — but it costs nothing.)
        Keychain.migrateAccessIfNeeded()
        TokenStore.migrateIfNeeded()

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

        let dashboards = NSMenuItem(title: "Dashboards…", action: #selector(openDashboards), keyEquivalent: "")
        dashboards.target = self
        dashboards.isEnabled = !model.allDashboards.isEmpty
        menu.addItem(dashboards)

        let connection = NSMenuItem(title: "Connection…", action: #selector(openConnection), keyEquivalent: "")
        connection.target = self
        menu.addItem(connection)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Homestead",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        status.setIcon(HouseIcon.image(snapshot: model?.snapshot ?? Snapshot(), appearance: appearance))
    }
}

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
